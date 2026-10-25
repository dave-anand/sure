class PortfolioSnapshotConnection < ApplicationRecord
  belongs_to :family
  belongs_to :account
  has_one :account_provider, as: :provider, dependent: :destroy
  has_many :portfolio_snapshots, dependent: :destroy

  validates :source, :source_account_id, presence: true
  validates :source, length: { maximum: 100 }
  validates :source_account_id, length: { maximum: 255 }
  validates :account_id, uniqueness: true
  validates :source_account_id, uniqueness: { scope: [ :family_id, :source ] }
  validate :account_matches_family

  def raw_payload
    portfolio_snapshots.order(as_of: :desc).first&.payload
  end

  private
    def account_matches_family
      errors.add(:account, "must belong to the same family") if account && account.family_id != family_id
    end
end
