class PortfolioSnapshot < ApplicationRecord
  include Encryptable

  encrypts :payload if encryption_ready?

  belongs_to :portfolio_snapshot_connection
  validates :as_of, :checksum, :payload, presence: true
  validates :as_of, uniqueness: { scope: :portfolio_snapshot_connection_id }

  class InvalidPayload < ArgumentError; end
  class Conflict < StandardError; end
end
