class Provider::PortfolioSnapshotAdapter < Provider::Base
  include Provider::InstitutionMetadata
  Provider::Factory.register("PortfolioSnapshotConnection", self)

  def provider_name
    "portfolio_snapshot"
  end
end
