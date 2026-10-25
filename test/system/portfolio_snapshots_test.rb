require "application_system_test_case"

class PortfolioSnapshotsTest < ApplicationSystemTestCase
  setup do
    @previous = Rails.application.config.x.local_file_imports_only
    Rails.application.config.x.local_file_imports_only = true
    @user = users(:family_admin)
    sign_in @user
    @account = @user.family.accounts.create!(name: "Snapshot investment", owner: @user,
      accountable: Investment.new, balance: 0, cash_balance: 0, currency: "USD")
    payload = PortfolioSnapshot::Payload.new({
      schema_version: 1, source: "browser-fixture", source_account_id: "fixture-1", account_id: @account.id,
      as_of: Date.current.iso8601, currency: "USD", balance: "100", cash_balance: "100", holdings: []
    })
    publisher = PortfolioSnapshot::Publisher.new(user: @user, payload: payload)
    publisher.publish!(expected_revision: publisher.preview[:revision])
  end

  teardown do
    Rails.application.config.x.local_file_imports_only = @previous
  end

  test "published accounts remain visible and navigable" do
    visit accounts_url
    assert_text "Local files only"
    card = find("#portfolio-snapshot-accounts")
    page.execute_script("arguments[0].scrollIntoView({block: 'center'})", card)
    within "#portfolio-snapshot-accounts" do
      assert_text "Portfolio snapshots"
      assert_text @account.name
      page.save_screenshot(Rails.root.join("tmp/screenshots/portfolio-snapshot-accounts.png"))
      click_link @account.name
    end
    assert_current_path account_path(@account)
    assert_text @account.name
  end
end
