# Reversible instance policy: imported observations and local calculations remain
# available, while live integrations cannot become competing financial writers.
module LocalFileMode
  class ExternalIntegrationDisabled < StandardError; end

  EXTERNAL_JOBS = %w[ImportMarketDataJob SyncHourlyJob SyncPropertyValuationsJob SecurityHealthCheckJob].freeze

  def self.enabled?
    Rails.application.config.x.local_file_imports_only == true
  end

  def self.provider_keys
    (Provider::Metadata::REGISTRY.keys.map(&:to_s) - [ "portfolio_snapshot" ]) + %w[openai anthropic jev]
  end

  def self.external_controller?(path)
    return true if %w[settings/providers api/v1/provider_connections].include?(path)
    path.split("/").any? do |part|
      provider_keys.any? { |key| part == key || part.start_with?("#{key}_") }
    end
  end

  def self.external_job?(job)
    name = job.class.name.delete(":")
    EXTERNAL_JOBS.include?(name) || provider_keys.any? { |key| name.start_with?(key.camelize) }
  end
end
