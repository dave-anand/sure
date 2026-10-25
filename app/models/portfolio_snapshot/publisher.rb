require "digest"

class PortfolioSnapshot::Publisher
  attr_reader :user, :payload

  def initialize(user:, payload:)
    @user = user
    @payload = payload
  end

  def preview
    account = writable_account
    connection = source_connection
    validate_mapping!(account, connection)
    {
      revision: revision(account, connection), checksum: payload.checksum,
      account_id: account.id, as_of: payload.data["as_of"], currency: account.currency,
      balance: payload.data["balance"], cash_balance: payload.data["cash_balance"],
      holdings_count: payload.data["holdings"].size
    }
  end

  def publish!(expected_revision:)
    user.family.with_lock do
      account = writable_account
      account.with_lock do
        raise ActiveRecord::RecordNotFound unless user.family.accounts.visible.writable_by(user).exists?(id: account.id)
        connection = source_connection
        validate_mapping!(account, connection)
        existing = connection&.portfolio_snapshots&.find_by(as_of: payload.as_of)
        if existing
          raise PortfolioSnapshot::Conflict, "A different snapshot already exists for this source and date" unless existing.checksum == payload.checksum
          return existing
        end
        unless expected_revision.present? && expected_revision == revision(account, connection)
          raise PortfolioSnapshot::Conflict, "Preview is stale or missing; preview again before publishing"
        end

        first_snapshot = connection.nil?
        connection ||= PortfolioSnapshotConnection.create!(
          family: user.family, account: account,
          source: payload.data["source"], source_account_id: payload.data["source_account_id"]
        )
        provider = connection.account_provider || connection.create_account_provider!(account: account)
        account.reload
        if first_snapshot && (placeholder = account.entries.valuations.first)
          placeholder.entryable.update!(kind: "current_anchor")
          placeholder.update!(date: payload.as_of, amount: payload.data["balance"].to_d)
        end
        import_positions!(account, provider)
        result = account.set_current_balance(payload.data["balance"].to_d, date: payload.as_of, schedule_sync: false)
        raise PortfolioSnapshot::InvalidPayload, "Could not anchor snapshot balance" unless result.success?

        connection.update!(last_snapshot_on: payload.as_of, security_mappings: connection.security_mappings.merge(security_mappings))
        snapshot = connection.portfolio_snapshots.create!(as_of: payload.as_of, checksum: payload.checksum, payload: payload.data)
        account.reload
        account.update!(cash_balance: payload.data["cash_balance"].to_d)
        # Store the observed date only. Reconstructing an entire daily history
        # from positions without trades would imply activity we do not know.
        observed = account.balances.find_or_initialize_by(date: payload.as_of, currency: account.currency)
        observed.update!(balance: payload.data["balance"].to_d, cash_balance: payload.data["cash_balance"].to_d,
          start_cash_balance: payload.data["cash_balance"].to_d,
          start_non_cash_balance: payload.data["balance"].to_d - payload.data["cash_balance"].to_d,
          cash_inflows: 0, cash_outflows: 0, non_cash_inflows: 0, non_cash_outflows: 0,
          net_market_flows: 0, cash_adjustments: 0, non_cash_adjustments: 0, flows_factor: 1)
        snapshot
      end
    end
  end

  private
    def writable_account
      user.family.accounts.visible.writable_by(user).find(payload.data["account_id"])
    end

    def source_connection
      PortfolioSnapshotConnection.uncached do
        PortfolioSnapshotConnection.find_by(family: user.family, source: payload.data["source"], source_account_id: payload.data["source_account_id"])
      end
    end

    def revision(account, connection)
      state = [ account.updated_at, connection&.updated_at, account.holdings.maximum(:updated_at),
        account.entries.maximum(:updated_at), account.account_shares.maximum(:updated_at) ]
      Digest::SHA256.hexdigest([ payload.checksum, *state.map { |time| time&.iso8601(6) } ].join(":"))
    end

    def security_mappings
      payload.data["holdings"].to_h { |position| position.values_at("source_security_id", "security_id") }
    end

    def validate_mapping!(account, connection)
      invalid!("Only investment accounts are supported") unless account.investment?
      invalid!("Snapshot-only accounts cannot contain transactions or trades") if account.transactions.exists? || account.trades.exists?
      invalid!("Snapshot currency must match account currency; mixed-currency positions require a separate adapter") unless account.currency == payload.data["currency"]
      raise PortfolioSnapshot::Conflict, "Source account is already mapped to a different account" if connection && connection.account_id != account.id
      if connection
        if connection.last_snapshot_on && payload.as_of < connection.last_snapshot_on && !connection.portfolio_snapshots.exists?(as_of: payload.as_of, checksum: payload.checksum)
          raise PortfolioSnapshot::Conflict, "Out-of-order snapshot; use a newer date"
        end
        security_mappings.each do |source_id, security_id|
          previous = connection.security_mappings[source_id]
          raise PortfolioSnapshot::Conflict, "Source security mapping changed; review the mapping" if previous && previous != security_id
        end
        unless account.account_providers.count == 1 && connection.account_provider&.account_id == account.id
          raise PortfolioSnapshot::Conflict, "Snapshot connection is no longer the exclusive writer"
        end
      else
        unless empty_target?(account)
          raise PortfolioSnapshot::Conflict, "First publication requires an empty, zero-balance investment account with no provider"
        end
      end
      ids = security_mappings.values
      invalid!("Map every position to an existing security") unless Security.where(id: ids).count == ids.size
    end

    def empty_target?(account)
      account.balance&.zero? && account.cash_balance&.zero? && !account.linked? &&
        account.portfolio_snapshot_connection.nil? && !account.holdings.exists? &&
        account.entries.count <= 1 && !account.entries.where.not(entryable_type: "Valuation").exists? &&
        !account.entries.where.not(amount: 0).exists? &&
        !account.balances.where("balance <> 0 OR end_balance <> 0 OR cash_balance <> 0").exists?
    end

    def import_positions!(account, provider)
      positions = payload.data["holdings"].index_by { |position| position["security_id"] }
      # A complete empty/closed position set must supersede the old provider
      # snapshot too, otherwise the latest-holdings selector resurrects it.
      prior_ids = account.holdings.where(account_provider: provider).distinct.pluck(:security_id)
      (prior_ids | positions.keys).each do |security_id|
        position = positions[security_id]
        basis = position&.fetch("cost_basis_total")
        unit_basis = basis && (basis.to_d / position.fetch("quantity").to_d).round(4)
        Account::ProviderImportAdapter.new(account).import_holding(
          security: Security.find(security_id), date: payload.as_of, currency: account.currency,
          quantity: position&.fetch("quantity") || "0", price: position&.fetch("price") || "0",
          amount: position&.fetch("amount") || "0", cost_basis: unit_basis,
          source: "portfolio_snapshot", account_provider_id: provider.id
        )
      end
    end

    def invalid!(message)
      raise PortfolioSnapshot::InvalidPayload, message
    end
end
