require "json"
require "net/http"
require "uri"

# Standalone so a scheduled collector does not need a Rails/database connection.
class PortfolioSnapshotClient
  class Error < StandardError; end

  def initialize(url:, api_key:, allow_http: false)
    @uri = URI.parse(url)
    unless %w[http https].include?(@uri.scheme) && @uri.host && !@uri.userinfo && !@uri.query && !@uri.fragment
      raise Error, "Use an HTTP(S) application URL without credentials, query or fragment"
    end
    if @uri.scheme == "http" && !allow_http && !%w[localhost 127.0.0.1 ::1].include?(@uri.hostname)
      raise Error, "Use HTTPS or explicitly allow HTTP for your private deployment"
    end
    raise Error, "Set SURE_API_KEY" if api_key.nil? || api_key.strip.empty?
    @api_key = api_key
  rescue URI::InvalidURIError
    raise Error, "Invalid application URL"
  end

  def preview(payload)
    request(:post, "portfolio_snapshots/preview", portfolio_snapshot: payload)
  end

  def publish(payload)
    revision = preview(payload).fetch("revision")
    request(:post, "portfolio_snapshots", portfolio_snapshot: payload, expected_revision: revision)
  end

  def status(id)
    raise Error, "Invalid snapshot ID" unless /\A[0-9a-f-]{36}\z/i.match?(id.to_s)
    request(:get, "portfolio_snapshots/#{id}")
  end

  private
    def request(method, path, body = nil)
      uri = @uri.dup
      uri.path = "#{uri.path.sub(%r{/+\z}, '')}/api/v1/#{path}"
      klass = method == :get ? Net::HTTP::Get : Net::HTTP::Post
      request = klass.new(uri)
      request["X-Api-Key"] = @api_key
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 60) do |http|
        http.request(request)
      end
      # Never follow redirects with the API key, or echo server HTML/payloads.
      raise Error, "Snapshot request returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body).fetch("data")
      raise Error, "Invalid snapshot response" unless data.is_a?(Hash)
      data
    rescue JSON::ParserError, KeyError
      raise Error, "Invalid snapshot response"
    rescue Timeout::Error, SocketError, SystemCallError, EOFError, OpenSSL::SSL::SSLError
      raise Error, "Snapshot request could not complete; retry unchanged input or check status"
    end
end
