require "test_helper"

class LocalFileModeTest < ActiveSupport::TestCase
  setup do
    @previous = Rails.application.config.x.local_file_imports_only
    Rails.application.config.x.local_file_imports_only = true
  end

  teardown do
    Rails.application.config.x.local_file_imports_only = @previous
  end

  test "blocks live provider resolution and execution" do
    assert_nil Provider::Registry.get_provider(:yahoo_finance)
    assert_nil Provider::Registry.plaid_provider_for_region(:us)
    assert_empty Provider::Registry.for_concept(:securities).providers
    called = false
    result = Provider.new.send(:with_provider_response) { called = true }
    assert_not called
    assert_not result.success?
    assert_match /disabled/, result.error.message
    assert_not AutoSyncScheduler.send(:enabled?)
    assert_not MarketDataScheduler.send(:enabled?)
  end

  test "recognizes live controller and namespaced job entrypoints" do
    %w[settings/providers api/v1/provider_connections plaid_items simplefin_items financekit_accounts].each do |path|
      assert LocalFileMode.external_controller?(path), path
    end
    assert_not LocalFileMode.external_controller?("api/v1/portfolio_snapshots")
    assert_not LocalFileMode.external_controller?("imports")
    assert LocalFileMode.external_job?(SimplefinItem::BalancesOnlyJob.new)
    assert LocalFileMode.external_job?(PlaidTransactionsRefreshAllJob.new)
    assert_not LocalFileMode.external_job?(ImportJob.new)
    PlaidTransactionsRefreshAllJob.any_instance.expects(:perform).never
    PlaidTransactionsRefreshAllJob.perform_now
  end

  test "family recalculation excludes live providers" do
    family = families(:dylan_family)
    children = Family::Syncer.new(family).send(:child_syncables)
    assert children.all? { |child| child.is_a?(Account) && !child.linked? }
  end
end
