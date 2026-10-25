class Api::V1::PortfolioSnapshotsController < Api::V1::BaseController
  before_action -> { response.headers["Cache-Control"] = "private, no-store" }
  before_action -> { authorize_scope!(:read) }, only: :show
  before_action -> { authorize_scope!(:write) }, only: [ :preview, :create ]
  before_action :reject_guest_writes!, only: [ :preview, :create ]

  rescue_from PortfolioSnapshot::InvalidPayload, with: :invalid_snapshot
  rescue_from PortfolioSnapshot::Conflict, with: :conflicting_snapshot

  def preview
    render json: { data: publisher.preview }
  end

  def create
    snapshot = publisher.publish!(expected_revision: params[:expected_revision])
    render_snapshot(snapshot, status: :created)
  rescue ActiveRecord::RecordInvalid => error
    DebugLogEntry.capture(category: "provider_sync", level: "error", message: "Portfolio snapshot publication failed",
      source: self.class.name, family: current_resource_owner.family, metadata: { error_class: error.class.name })
    render json: { error: "validation_failed", message: "Snapshot could not be published" }, status: :unprocessable_entity
  end

  def show
    account_ids = current_resource_owner.family.accounts.accessible_by(current_resource_owner).select(:id)
    snapshot = PortfolioSnapshot.joins(:portfolio_snapshot_connection)
      .where(portfolio_snapshot_connections: { family_id: current_resource_owner.family_id, account_id: account_ids }).find(params[:id])
    render_snapshot(snapshot)
  end

  private
    def publisher
      input = params.require(:portfolio_snapshot)
      raise PortfolioSnapshot::InvalidPayload, "portfolio_snapshot must be an object" unless input.is_a?(ActionController::Parameters)
      payload = PortfolioSnapshot::Payload.new(input.to_unsafe_h)
      PortfolioSnapshot::Publisher.new(user: current_resource_owner, payload: payload)
    end

    def render_snapshot(snapshot, status: :ok)
      connection = snapshot.portfolio_snapshot_connection
      render json: { data: {
        id: snapshot.id, status: "complete", account_id: connection.account_id,
        source: connection.source, source_account_id: connection.source_account_id,
        as_of: snapshot.as_of.iso8601, checksum: snapshot.checksum,
        balance: snapshot.payload["balance"], cash_balance: snapshot.payload["cash_balance"],
        currency: snapshot.payload["currency"], holdings_count: snapshot.payload["holdings"].size
      } }, status: status
    end

    def invalid_snapshot(error)
      render json: { error: "validation_failed", message: error.message }, status: :unprocessable_entity
    end

    def conflicting_snapshot(error)
      render json: { error: "snapshot_conflict", message: error.message }, status: :conflict
    end
end
