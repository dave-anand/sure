require "digest"
require "json"
require "bigdecimal"

# A complete position snapshot, never a stream of trades or cash movements.
class PortfolioSnapshot::Payload
  ROOT_KEYS = %w[schema_version source source_account_id account_id as_of currency balance cash_balance holdings].freeze
  HOLDING_KEYS = %w[source_security_id security_id quantity price amount cost_basis_total].freeze
  MAX_HOLDINGS = 500

  attr_reader :data, :checksum

  def initialize(input)
    invalid!("snapshot must be an object") unless input.is_a?(Hash)
    input = input.deep_stringify_keys
    reject_unknown!(input, ROOT_KEYS)
    invalid!("schema_version must be the integer 1") unless input["schema_version"].is_a?(Integer) && input["schema_version"] == 1
    invalid!("currency must be CAD or USD") unless %w[CAD USD].include?(input["currency"])
    holdings = input["holdings"]
    invalid!("holdings must contain at most #{MAX_HOLDINGS} positions") unless holdings.is_a?(Array) && holdings.size <= MAX_HOLDINGS

    @data = {
      "schema_version" => 1,
      "source" => identifier(input["source"], "source", 100),
      "source_account_id" => identifier(input["source_account_id"], "source_account_id", 255),
      "account_id" => uuid(input["account_id"], "account_id"),
      "as_of" => snapshot_date(input["as_of"]),
      "currency" => input["currency"],
      "balance" => decimal(input["balance"], "balance"),
      "cash_balance" => decimal(input["cash_balance"], "cash_balance"),
      "holdings" => holdings.map { |holding| normalize_holding(holding) }.sort_by { |holding| holding["source_security_id"] }
    }
    %w[source_security_id security_id].each do |key|
      values = @data["holdings"].map { |holding| holding[key] }
      invalid!("holdings contain duplicate #{key}") unless values.uniq.size == values.size
    end
    total = BigDecimal(@data["cash_balance"]) + @data["holdings"].sum { |holding| BigDecimal(holding["amount"]) }
    invalid!("balance must equal cash_balance plus holdings within 0.01") if (total - BigDecimal(@data["balance"])).abs > BigDecimal("0.01")
    @checksum = Digest::SHA256.hexdigest(JSON.generate(@data))
  end

  def as_of
    Date.iso8601(data.fetch("as_of"))
  end

  private
    def normalize_holding(input)
      invalid!("holding must be an object") unless input.is_a?(Hash)
      reject_unknown!(input, HOLDING_KEYS)
      result = {
        "source_security_id" => identifier(input["source_security_id"], "source_security_id", 255),
        "security_id" => uuid(input["security_id"], "security_id"),
        "quantity" => decimal(input["quantity"], "quantity", scale: 18, integers: 16),
        "price" => decimal(input["price"], "price"),
        "amount" => decimal(input["amount"], "amount"),
        "cost_basis_total" => input["cost_basis_total"].nil? ? nil : decimal(input["cost_basis_total"], "cost_basis_total")
      }
      invalid!("holding quantity must be positive; omit closed positions") unless BigDecimal(result["quantity"]).positive?
      if result["cost_basis_total"] && BigDecimal(result["cost_basis_total"]) / BigDecimal(result["quantity"]) >= BigDecimal("1000000000000000")
        invalid!("unit cost basis exceeds supported precision")
      end
      computed = BigDecimal(result["quantity"]) * BigDecimal(result["price"])
      invalid!("holding amount must equal quantity times price within 0.01") if (computed - BigDecimal(result["amount"])).abs > BigDecimal("0.01")
      result
    end

    def identifier(value, key, maximum)
      invalid!("#{key} must be a nonblank string of at most #{maximum} characters") unless value.is_a?(String) && value.strip.present? && value.size <= maximum
      value.strip
    end

    def uuid(value, key)
      invalid!("#{key} must be a UUID") unless value.is_a?(String) && UuidFormat.valid?(value)
      value.downcase
    end

    def decimal(value, key, scale: 4, integers: 15)
      pattern = /\A\d{1,#{integers}}(?:\.\d{1,#{scale}})?\z/
      invalid!("#{key} must be a nonnegative decimal string (#{integers} integer and #{scale} fractional digits maximum)") unless value.is_a?(String) && pattern.match?(value)
      BigDecimal(value).to_s("F")
    end

    def snapshot_date(value)
      invalid!("as_of must be an ISO date") unless value.is_a?(String) && /\A\d{4}-\d{2}-\d{2}\z/.match?(value)
      date = Date.iso8601(value)
      invalid!("as_of must be supported and cannot be in the future") unless date > Entry.min_supported_date && date <= Date.current
      date.iso8601
    rescue Date::Error
      invalid!("as_of must be an ISO date")
    end

    def reject_unknown!(input, allowed)
      invalid!("unknown snapshot fields") if (input.keys - allowed).any?
    end

    def invalid!(message)
      raise PortfolioSnapshot::InvalidPayload, message
    end
end
