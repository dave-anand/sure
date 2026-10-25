require "test_helper"

class Api::V1::PortfolioSnapshotsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @key = ApiKey.create!(user: @user, name: "Snapshot tests", scopes: [ "read_write" ], source: "web", display_key: ApiKey.generate_secure_key)
    @read_key = ApiKey.create!(user: @user, name: "Snapshot reads", scopes: [ "read" ], source: "mobile", display_key: ApiKey.generate_secure_key)
    @account = @user.family.accounts.create!(name: "API snapshot", owner: @user,
      accountable: Investment.new, balance: 0, cash_balance: 0, currency: "CAD")
    @input = { schema_version: 1, source: "fixture-export", source_account_id: "source-1",
      account_id: @account.id, as_of: Date.current.iso8601, currency: "CAD", balance: "100", cash_balance: "100", holdings: [] }
  end

  test "previews without writes, publishes, reads and replays" do
    assert_no_difference [ "PortfolioSnapshot.count", "Entry.count", "Holding.count" ] do
      post preview_api_v1_portfolio_snapshots_url, params: { portfolio_snapshot: @input }, headers: api_headers(@key), as: :json
    end
    assert_response :success
    revision = response.parsed_body.dig("data", "revision")
    post api_v1_portfolio_snapshots_url, params: { portfolio_snapshot: @input, expected_revision: revision }, headers: api_headers(@key), as: :json
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    get api_v1_portfolio_snapshot_url(id), headers: api_headers(@read_key)
    assert_response :success
    assert_equal "complete", response.parsed_body.dig("data", "status")
    assert_no_difference "PortfolioSnapshot.count" do
      post api_v1_portfolio_snapshots_url, params: { portfolio_snapshot: @input, expected_revision: revision }, headers: api_headers(@key), as: :json
      assert_response :created
      assert_equal id, response.parsed_body.dig("data", "id")
    end
  end

  test "requires authentication and blocks read-only writes" do
    post preview_api_v1_portfolio_snapshots_url, params: { portfolio_snapshot: @input }, as: :json
    assert_response :unauthorized
    [ preview_api_v1_portfolio_snapshots_url, api_v1_portfolio_snapshots_url ].each do |url|
      post url, params: { portfolio_snapshot: @input }, headers: api_headers(@read_key), as: :json
      assert_response :forbidden
    end
  end

  test "returns validation errors for invalid parameters and dates" do
    [ @input.merge(as_of: "invalid"), @input.merge(balance: "0"), @input.merge(cash_balance: 100) ].each do |input|
      post preview_api_v1_portfolio_snapshots_url, params: { portfolio_snapshot: input }, headers: api_headers(@key), as: :json
      assert_response :unprocessable_entity
    end
  end

  test "rejects missing or stale preview revisions" do
    post api_v1_portfolio_snapshots_url, params: { portfolio_snapshot: @input }, headers: api_headers(@key), as: :json
    assert_response :conflict
    assert_equal 0, PortfolioSnapshot.count
  end

  test "hides cross-family and unshared accounts and snapshot status" do
    other_user = users(:empty)
    other = other_user.family.accounts.create!(name: "Other household", owner: other_user,
      accountable: Investment.new, balance: 0, cash_balance: 0, currency: "CAD")
    @input[:account_id] = other.id
    post preview_api_v1_portfolio_snapshots_url, params: { portfolio_snapshot: @input }, headers: api_headers(@key), as: :json
    assert_response :not_found
    @input[:account_id] = @account.id
    post preview_api_v1_portfolio_snapshots_url, params: { portfolio_snapshot: @input }, headers: api_headers(@key), as: :json
    revision = response.parsed_body.dig("data", "revision")
    post api_v1_portfolio_snapshots_url, params: { portfolio_snapshot: @input, expected_revision: revision }, headers: api_headers(@key), as: :json
    id = response.parsed_body.dig("data", "id")
    @account.update!(owner: users(:family_member))
    get api_v1_portfolio_snapshot_url(id), headers: api_headers(@key)
    assert_response :not_found
    get api_v1_portfolio_snapshot_url(SecureRandom.uuid), headers: api_headers(@key)
    assert_response :not_found
  end

  test "local file mode blocks live connections while preserving file publication" do
    previous = Rails.application.config.x.local_file_imports_only
    Rails.application.config.x.local_file_imports_only = true
    get api_v1_provider_connections_url, as: :json
    assert_response :unauthorized
    get api_v1_provider_connections_url, headers: api_headers(@key), as: :json
    assert_response :forbidden
    assert_equal "local_file_mode", response.parsed_body["error"]
    post preview_api_v1_portfolio_snapshots_url, params: { portfolio_snapshot: @input }, headers: api_headers(@key), as: :json
    assert_response :success
    revision = response.parsed_body.dig("data", "revision")
    post api_v1_portfolio_snapshots_url, params: { portfolio_snapshot: @input, expected_revision: revision }, headers: api_headers(@key), as: :json
    assert_response :created
  ensure
    Rails.application.config.x.local_file_imports_only = previous
  end

  private
    def api_headers(key)
      { "X-Api-Key" => key.display_key }
    end
end
