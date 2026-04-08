require "net/http"
require "json"
require "uri"

module MysqlGenius
  class AiClient
    MAX_REDIRECTS = 3

    def initialize
      @config = MysqlGenius.configuration
    end

    def chat(messages:, temperature: 0)
      if @config.ai_client
        return @config.ai_client.call(messages: messages, temperature: temperature)
      end

      raise Error, "AI is not configured" unless @config.ai_endpoint && @config.ai_api_key

      body = {
        messages: messages,
        response_format: { type: "json_object" },
        temperature: temperature
      }
      body[:model] = @config.ai_model if @config.ai_model.present?

      response = post_with_redirects(URI(@config.ai_endpoint), body.to_json)
      parsed = JSON.parse(response.body)

      if parsed["error"]
        raise Error, "AI API error: #{parsed['error']['message'] || parsed['error']}"
      end

      content = parsed.dig("choices", 0, "message", "content")
      raise Error, "No content in AI response" if content.nil?

      parse_json_content(content)
    end

    private

    def parse_json_content(content)
      # Try direct parse first
      JSON.parse(content)
    rescue JSON::ParserError
      # Strip markdown code fences that some models wrap around JSON
      stripped = content.to_s
        .gsub(/\A\s*```(?:json)?\s*/i, "")
        .gsub(/\s*```\s*\z/, "")
        .strip
      begin
        JSON.parse(stripped)
      rescue JSON::ParserError
        { "raw" => content.to_s }
      end
    end

    def post_with_redirects(uri, body, redirects = 0)
      raise Error, "Too many redirects" if redirects > MAX_REDIRECTS

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 60

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      if @config.ai_auth_style == :bearer
        request["Authorization"] = "Bearer #{@config.ai_api_key}"
      else
        request["api-key"] = @config.ai_api_key
      end
      request.body = body

      response = http.request(request)

      if response.is_a?(Net::HTTPRedirection)
        post_with_redirects(URI(response["location"]), body, redirects + 1)
      else
        response
      end
    end
  end
end
