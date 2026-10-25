require "test_helper"
require Rails.root.join("lib/portfolio_snapshot_client")

class PortfolioSnapshotClientTest < ActiveSupport::TestCase
  setup do
    @client = PortfolioSnapshotClient.new(url: "https://sure.example", api_key: "test-key")
  end

  test "previews then publishes the same payload with its revision" do
    payload = { "schema_version" => 1 }
    stub_request(:post, "https://sure.example/api/v1/portfolio_snapshots/preview")
      .with(headers: { "X-Api-Key" => "test-key" }, body: { portfolio_snapshot: payload }.to_json)
      .to_return(body: { data: { revision: "revision-1" } }.to_json)
    stub_request(:post, "https://sure.example/api/v1/portfolio_snapshots")
      .with(body: { portfolio_snapshot: payload, expected_revision: "revision-1" }.to_json)
      .to_return(body: { data: { status: "complete", id: "snapshot-id" } }.to_json)
    assert_equal "complete", @client.publish(payload)["status"]
  end

  test "does not follow redirects or disclose server response bodies" do
    stub_request(:post, "https://sure.example/api/v1/portfolio_snapshots/preview")
      .to_return(status: 302, headers: { "Location" => "https://other.example" }, body: "private account data")
    error = assert_raises(PortfolioSnapshotClient::Error) { @client.preview({}) }
    assert_equal "Snapshot request returned HTTP 302", error.message
    assert_not_requested :get, "https://other.example"
  end

  test "rejects credential URLs and implicit nonlocal HTTP" do
    [ "https://user:pass@sure.example", "http://192.168.1.10:3000", "https://sure.example?key=secret" ].each do |url|
      assert_raises(PortfolioSnapshotClient::Error) { PortfolioSnapshotClient.new(url: url, api_key: "key") }
    end
  end
end
