require 'swagger_helper'

RSpec.describe 'API V1 Portfolio Snapshots', type: :request do
  let(:family) { Family.create!(name: 'Snapshot docs', currency: 'CAD', locale: 'en') }
  let(:user) { family.users.create!(email: 'snapshot-docs@example.com', password: 'password123', role: 'admin') }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: 'API Docs Key', key: key, scopes: %w[read_write], source: 'web')
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:account) { family.accounts.create!(name: 'Snapshot investment', owner: user, accountable: Investment.new, balance: 0, currency: 'CAD') }
  let(:input) do
    { schema_version: 1, source: 'broker-export', source_account_id: 'broker-1', account_id: account.id,
      as_of: Date.current.iso8601, currency: 'CAD', balance: '100', cash_balance: '100', holdings: [] }
  end
  let(:publisher) { PortfolioSnapshot::Publisher.new(user: user, payload: PortfolioSnapshot::Payload.new(input)) }

  path '/api/v1/portfolio_snapshots/preview' do
    post 'Preview a mapped account and holdings snapshot without writing' do
      tags 'Portfolio Snapshots'
      consumes 'application/json'
      produces 'application/json'
      security [ apiKeyAuth: [] ]
      parameter name: :request_body, in: :body, schema: {
        type: :object, required: %w[portfolio_snapshot],
        properties: { portfolio_snapshot: { '$ref' => '#/components/schemas/PortfolioSnapshotInput' } }
      }
      let(:request_body) { { portfolio_snapshot: input } }
      response '200', 'reconciled preview and revision' do
        schema '$ref' => '#/components/schemas/PortfolioSnapshotPreviewResponse'
        run_test!
      end
      response('401', 'missing authentication') { let(:'X-Api-Key') { nil }; run_test! }
      response '403', 'read-only scope or guest' do
        let(:api_key) { super().tap { |key| key.update!(scopes: %w[read]) } }
        run_test!
      end
      response '404', 'account not writable or not found' do
        let(:input) { super().merge(account_id: SecureRandom.uuid) }
        run_test!
      end
      response '409', 'source mapping or date conflicts' do
        before { account.update!(balance: 1) }
        run_test!
      end
      response '422', 'invalid snapshot' do
        let(:request_body) { { portfolio_snapshot: input.merge(balance: '0') } }
        run_test!
      end
    end
  end

  path '/api/v1/portfolio_snapshots' do
    post 'Atomically publish a snapshot or return its identical replay' do
      tags 'Portfolio Snapshots'
      description 'Requires an empty investment account on first use. Same-date corrections and out-of-order snapshots return 409. No trades are created.'
      consumes 'application/json'
      produces 'application/json'
      security [ apiKeyAuth: [] ]
      parameter name: :request_body, in: :body, schema: {
        type: :object, required: %w[portfolio_snapshot expected_revision],
        properties: { portfolio_snapshot: { '$ref' => '#/components/schemas/PortfolioSnapshotInput' }, expected_revision: { type: :string } }
      }
      let(:request_body) { { portfolio_snapshot: input, expected_revision: publisher.preview[:revision] } }
      response '201', 'published or identically replayed snapshot' do
        schema '$ref' => '#/components/schemas/PortfolioSnapshotResponse'
        run_test!
      end
      response('401', 'missing authentication') { let(:'X-Api-Key') { nil }; run_test! }
      response '403', 'read-only scope or guest' do
        let(:api_key) { super().tap { |key| key.update!(scopes: %w[read]) } }
        run_test!
      end
      response '404', 'account not writable or not found' do
        let(:request_body) { { portfolio_snapshot: input.merge(account_id: SecureRandom.uuid), expected_revision: 'unavailable' } }
        run_test!
      end
      response '409', 'stale or missing preview revision or conflicting data' do
        let(:request_body) { { portfolio_snapshot: input } }
        run_test!
      end
      response '422', 'invalid snapshot' do
        let(:request_body) { { portfolio_snapshot: input.merge(balance: '0'), expected_revision: 'invalid' } }
        run_test!
      end
    end
  end

  path '/api/v1/portfolio_snapshots/{id}' do
    parameter name: :id, in: :path, type: :string, format: :uuid
    get 'Read publication status for an accessible account' do
      tags 'Portfolio Snapshots'
      produces 'application/json'
      security [ apiKeyAuth: [] ]
      let(:id) { publisher.publish!(expected_revision: publisher.preview[:revision]).id }
      response '200', 'completed snapshot' do
        schema '$ref' => '#/components/schemas/PortfolioSnapshotResponse'
        run_test!
      end
      response('401', 'missing authentication') { let(:'X-Api-Key') { nil }; run_test! }
      response '404', 'not accessible or not found' do
        let(:id) { SecureRandom.uuid }
        run_test!
      end
    end
  end
end
