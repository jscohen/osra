class Orphan < ActiveRecord::Base

  enum status: [
    :active,
    :inactive,
    :on_hold,
    :under_revision
  ]

  enum sponsorship_status: [
    :unsponsored,
    :sponsored,
    :previously_sponsored,
    :sponsorship_on_hold
  ]

  AGE_OF_ELIGIBILITY_TO_JOIN = 22
  VALID_GESTATION = 1

  SPONSORSHIP_STATUS_ORDERING = %Q{
  CASE WHEN sponsorship_status = '#{Orphan.sponsorship_statuses[:previously_sponsored]}' THEN '1'
       WHEN sponsorship_status = '#{Orphan.sponsorship_statuses[:unsponsored]}'          THEN '2'
  END ASC
  }

  NEW_SPONSORSHIP_SORT_SQL = "#{SPONSORSHIP_STATUS_ORDERING}, priority ASC"

  include Initializer
  include DateHelpers
  include OrphanAttrFilter

  after_initialize :set_defaults

  before_update :qualify_for_sponsorship_by_status,
    if: :status_changed?

  before_validation :set_province_code

  before_create :generate_osra_num

  validates :name, presence: true,
            uniqueness: { scope: [:family_name, :mother_name, :father_given_name],
                          message: 'taken: an orphan with this name, father, mother & family name is already in the database.' }

  validates :father_given_name, presence: true
  validates :family_name, presence: true

  validates :father_deceased, exclusion: { in: [nil] }
  validates :father_is_martyr, exclusion: { in: [nil] }

  with_options :if => :father_deceased do |o|
    o.validates :father_date_of_death, valid_date_presence: true, date_not_in_future: true
  end

  with_options :unless => :father_deceased do |o|
    o.validates :father_date_of_death, absence: true
    o.validates :father_place_of_death, absence: true
    o.validates :father_cause_of_death, absence: true
    o.validates :father_is_martyr, inclusion: { in: [false] }
  end

  validates :mother_name, presence: true
  validates :mother_alive, inclusion: {in: [true, false] }, exclusion: { in: [nil]}
  validates :date_of_birth, valid_date_presence: true, date_not_in_future: true
  validates :gender, presence: true, inclusion: {in: Settings.lookup.gender }
  validates :contact_number, presence: true
  validates :sponsored_by_another_org, inclusion: {in: [true, false] }, exclusion: { in: [nil]}
  validates :minor_siblings_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 },  allow_nil: true
  validates :sponsored_minor_siblings_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :original_address, presence: true
  validates :current_address, presence: true
  validates :priority, presence: true, inclusion: { in: %w(Normal High) }
  validates :orphan_list, presence: true
  validate :sponsored_siblings_does_not_exceed_siblings_count
  validate :orphan_born_shortly_after_fathers_death,
    if: [:father_deceased,
         'valid_date?(date_of_birth)',
         'valid_date?(father_date_of_death)']
  validate :of_elibible_age_to_join, if: 'valid_date?(date_of_birth)'
  validate :can_be_inactivated, on: :update

  has_one :original_address, foreign_key: 'orphan_original_address_id', class_name: 'Address'
  has_one :current_address, foreign_key: 'orphan_current_address_id', class_name: 'Address'
  has_many :sponsorships
  has_many :sponsors, through: :sponsorships

  belongs_to :orphan_list
  has_one :partner, through: :orphan_list, autosave: false

  delegate :province_code, to: :partner, prefix: true

  accepts_nested_attributes_for :current_address, allow_destroy: true
  accepts_nested_attributes_for :original_address, allow_destroy: true

  default_scope { includes(:partner, original_address: :province) }

  scope :currently_unsponsored,
    -> { where(sponsorship_status: [ Orphan.sponsorship_statuses[:unsponsored],
                                     Orphan.sponsorship_statuses[:previously_sponsored] ]) }
  scope :high_priority, -> { where(priority: 'High') }
  scope :sort_by_eligibility, -> { active.currently_unsponsored.
                                   order(NEW_SPONSORSHIP_SORT_SQL) }

  acts_as_sequenced scope: :province_code

  def father_name
    "#{father_given_name} #{family_name}"
  end

  def full_name
    "#{name} #{father_given_name} #{family_name}"
  end

  def eligible_for_sponsorship?
    Orphan.active.currently_unsponsored.include? self
  end

  def current_sponsorship
    sponsorships.all_active.first if sponsored?
  end

  def current_sponsor
    current_sponsorship.sponsor if sponsored?
  end

private

  def set_defaults
    return if persisted?
    default_sponsorship_status_to_unsponsored
    default_status_to_active
    default_priority_to_normal
  end

  def default_sponsorship_status_to_unsponsored
    self.sponsorship_status ||= 'unsponsored'
  end

  def default_status_to_active
    self.status ||= 'active'
  end

  def default_priority_to_normal
    self.priority ||= 'Normal'
  end

  def set_province_code
    self.province_code ||= partner_province_code
  end

  def generate_osra_num
    self.osra_num = "#{province_code}%05d" % sequential_id
  end

  def sponsored_siblings_does_not_exceed_siblings_count
    if sponsored_siblings_exceed_total?
      errors.add(:sponsored_minor_siblings_count, 'cannot exceed minor siblings count')
    end
  end

  def sponsored_siblings_exceed_total?
    sponsored_minor_siblings_count.to_i > minor_siblings_count.to_i
  end

  def of_elibible_age_to_join
    if too_old_to_join_osra?
      errors.add :date_of_birth,
        "Orphan must be younger than #{AGE_OF_ELIGIBILITY_TO_JOIN} years old to join OSRA."
    end
  end

  def too_old_to_join_osra?
    date_of_birth + AGE_OF_ELIGIBILITY_TO_JOIN.years <= date_of_joining_osra
  end

  def date_of_joining_osra
    new_record? ? Date.current : created_at.to_date
  end

  def orphan_born_shortly_after_fathers_death
    if orphan_born_long_after_fathers_death?
      errors.add :date_of_birth,
                 "must be within #{VALID_GESTATION} year(s) of father's death"
    end
  end

  def orphan_born_long_after_fathers_death?
    (father_date_of_death + VALID_GESTATION.year) < date_of_birth
  end

  def can_be_inactivated
    if sponsored? && being_inactivated?
      errors.add :status,
        'Cannot inactivate orphan with active sponsorships'
    end
  end

  def being_inactivated?
    status_changed? && (status_was == 'active')
  end

  def qualify_for_sponsorship_by_status
    if active?
      new_status = ResolveOrphanSponsorshipStatus.new(self).call
      self.sponsorship_status = new_status
    elsif status_was == 'active'
      deactivate
    end
  end

  def deactivate
    self.sponsorship_status = 'sponsorship_on_hold'
  end
end
