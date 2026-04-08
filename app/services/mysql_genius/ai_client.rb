require "net/http"
require "json"
require "uri"

module MysqlGenius
  class AiClient
    def initialize
      @config = MysqlGenius.configuration
    end

    def chat(messages:, temperature: 0)
      if @config.ai_client
        return @config.ai_client.call(messages: messages, temperature: temperature)
      end

      raise Error, "AI is not configured" unless @config.ai_endpoint && @config.ai_api_key

      uri = URI(@config.ai_endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["api-key"] = @config.ai_api_key

      request.body = {
        messages: messages,
        response_format: { type: "json_object" },
        temperature: temperature
      }.to_json

      response = http.request(request)
      parsed = JSON.parse(response.body)

      if parsed["error"]
        raise Error, "AI API error: #{parsed['error']['message'] || parsed['error']}"
      end

      content = parsed.dig("choices", 0, "message", "content")
      raise Error, "No content in AI response" if content.nil?

      JSON.parse(content)
    rescue JSON::ParserError
      { "raw" => content.to_s }
    end
  end
end
