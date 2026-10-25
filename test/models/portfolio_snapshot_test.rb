require "test_helper"

class PortfolioSnapshotTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = @user.family.accounts.create!(name: "Snapshot investment", owner: @user,
      accountable: Investment.new, balance: 0, cash_balance: 0, currency: "USD")
    @security = securities(:aapl)
  end

  test "reconciles an authoritative snapshot without trades and survives normal sync" do
    snapshot = publish(input)
    @account.reload
    assert_equal 1100.to_d, @account.balance
    assert_equal 100.to_d, @account.cash_balance
    holding = @account.holdings.find_by!(date: Date.current, account_provider: @account.account_providers.sole)
    assert_equal 10.to_d, holding.qty
    assert_equal 90.to_d, holding.cost_basis
    assert_empty @account.trades
    assert_empty @account.transactions
    assert_equal Date.current, @account.opening_anchor_date

    Account::MarketDataImporter.any_instance.stubs(:import_all)
    Account::Syncer.new(@account).perform_sync(OpenStruct.new(window_start_date: nil))
    assert_equal 10.to_d, holding.reload.qty
    assert_equal 1100.to_d, @account.reload.balance
    assert_equal "900.0", snapshot.payload.dig("holdings", 0, "cost_basis_total")
  end

  test "equivalent formatting and position order share canonical checksum" do
    raw = input
    raw["holdings"] << raw["holdings"].first.merge("source_security_id" => "MSFT", "security_id" => securities(:msft).id)
    raw["balance"] = "2100"
    first = PortfolioSnapshot::Payload.new(raw)
    raw["holdings"].reverse!
    raw["balance"] = "2100.00"
    assert_equal first.checksum, PortfolioSnapshot::Payload.new(raw).checksum
  end

  test "keeps portfolio value but does not infer returns from missing contribution history" do
    known = @user.family.accounts.create!(name: "Known returns", owner: @user, accountable: Investment.new,
      balance: 1010, cash_balance: 0, currency: "USD")
    period = Period.current_month
    known.balances.create!(date: period.date_range.begin - 1.day, balance: 1000, currency: "USD", start_non_cash_balance: 1000)
    known.balances.create!(date: Date.current, balance: 1010, currency: "USD", start_non_cash_balance: 1000, net_market_flows: 10)
    statement = InvestmentStatement.new(@user.family, user: @user)
    assert_not_nil statement.period_return_trend(period: period)
    before = statement.portfolio_value
    publish(input)
    statement = InvestmentStatement.new(@user.family, user: @user)
    assert_equal before + 1100, statement.portfolio_value
    assert_nil statement.period_return_trend(period: period)
    @account.update!(owner: users(:family_member))
    assert_not_nil InvestmentStatement.new(@user.family, user: @user).period_return_trend(period: period)
  end

  test "same-date replay is idempotent and changed content conflicts" do
    publisher = PortfolioSnapshot::Publisher.new(user: @user, payload: PortfolioSnapshot::Payload.new(input))
    revision = publisher.preview[:revision]
    first = publisher.publish!(expected_revision: revision)
    assert_no_difference [ "PortfolioSnapshot.count", "Holding.count", "Entry.count" ] do
      assert_equal first.id, publisher.publish!(expected_revision: revision).id
    end
    changed = input.merge("cash_balance" => "101", "balance" => "1101")
    assert_raises(PortfolioSnapshot::Conflict) { publish(changed) }
  end

  test "closed positions have zero authoritative rows and are not resurrected" do
    publish(input)
    travel 1.day do
      publish(input.merge("as_of" => Date.current.iso8601, "holdings" => [], "balance" => "100"))
      assert_equal 0.to_d, @account.holdings.where(date: Date.current).sum(:amount)
      assert_equal 100.to_d, @account.reload.cash_balance
      assert_equal 100.to_d, @account.balance
      Account::MarketDataImporter.any_instance.stubs(:import_all)
      Account::Syncer.new(@account).perform_sync(OpenStruct.new(window_start_date: nil))
      assert_equal 0.to_d, @account.holdings.where(date: Date.current).sum(:amount)
    end
  end

  test "encrypts archived payloads when encryption is explicitly configured" do
    skip "Encryption requires explicit keys" unless PortfolioSnapshot.encryption_ready?
    snapshot = publish(input)
    assert snapshot.encrypted_attribute?(:payload)
    assert_equal "100.0", snapshot.reload.payload["cash_balance"]
  end

  test "unknown acquisition costs stay unknown and newer dates retain source identity" do
    raw = input
    raw["holdings"][0].delete("cost_basis_total")
    first = publish(raw)
    assert_nil @account.holdings.find_by!(date: Date.current).cost_basis
    connection = first.portfolio_snapshot_connection
    travel 1.day do
      second = publish(input)
      assert_equal connection.id, second.portfolio_snapshot_connection_id
      assert_equal 2, connection.portfolio_snapshots.count
      assert_equal first.id, PortfolioSnapshot::Publisher.new(user: @user, payload: PortfolioSnapshot::Payload.new(raw))
        .publish!(expected_revision: "original-retry").id
    end
  end

  test "stale previews and changed source mappings cannot publish" do
    publisher = PortfolioSnapshot::Publisher.new(user: @user, payload: PortfolioSnapshot::Payload.new(input))
    revision = publisher.preview[:revision]
    @account.update!(name: "Renamed after preview")
    assert_raises(PortfolioSnapshot::Conflict) { publisher.publish!(expected_revision: revision) }
    publish(input)
    travel 1.day do
      changed = input
      changed["holdings"][0]["security_id"] = securities(:msft).id
      assert_raises(PortfolioSnapshot::Conflict) { publish(changed) }
    end
  end

  test "rejects unmapped, ambiguous and unreconciled financial inputs" do
    [
      input.merge("balance" => "1099"),
      input.merge("cash_balance" => 100),
      input.merge("as_of" => "2026-02-30"),
      input.merge("as_of" => Date.tomorrow.iso8601),
      input.merge("future_assumption" => true),
      input.merge("holdings" => [ input["holdings"].first ] * 2),
      input.merge("holdings" => [ input["holdings"].first.merge("quantity" => "NaN") ]),
      input.merge("holdings" => [ input["holdings"].first.merge("price" => "1e2") ])
    ].each do |raw|
      assert_raises(PortfolioSnapshot::InvalidPayload) { PortfolioSnapshot::Payload.new(raw) }
    end
    assert_raises(PortfolioSnapshot::InvalidPayload) { publish(input.merge("currency" => "CAD")) }
  end

  test "rejects occupied accounts and cannot acquire another provider writer" do
    @account.update!(balance: 10)
    assert_raises(PortfolioSnapshot::Conflict) { publish(input) }
    @account.update!(balance: 0)
    publish(input)
    competing = AccountProvider.new(account: @account, provider: plaid_accounts(:one))
    assert_not competing.valid?
    assert competing.errors[:account].any?
  end

  test "all canonical writes roll back when saving the observed balance fails" do
    Balance.any_instance.stubs(:save!).raises("simulation failure")
    assert_no_difference [ "PortfolioSnapshotConnection.count", "PortfolioSnapshot.count", "Holding.count", "Entry.count" ] do
      assert_raises(RuntimeError) { publish(input) }
    end
    assert_equal 0.to_d, @account.reload.balance
  end

  test "latest observed date wins when multiple snapshots are uploaded together" do
    publish(input.merge("as_of" => Date.yesterday.iso8601))
    publish(input)
    holdings = Holding::CurrentForInvestmentAccounts.new([ @account.id ]).relation
    assert_equal 1, holdings.count
    assert_equal 10.to_d, holdings.sum(:qty)
  end

  private
    def input
      {
        "schema_version" => 1, "source" => "broker-export", "source_account_id" => "account-1",
        "account_id" => @account.id, "as_of" => Date.current.iso8601, "currency" => "USD",
        "balance" => "1100", "cash_balance" => "100",
        "holdings" => [ { "source_security_id" => "AAPL", "security_id" => @security.id,
          "quantity" => "10", "price" => "100", "amount" => "1000", "cost_basis_total" => "900" } ]
      }
    end

    def publish(raw)
      publisher = PortfolioSnapshot::Publisher.new(user: @user, payload: PortfolioSnapshot::Payload.new(raw))
      publisher.publish!(expected_revision: publisher.preview[:revision])
    end
end
