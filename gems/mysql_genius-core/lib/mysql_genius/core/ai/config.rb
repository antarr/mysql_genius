# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Keyword-init value object holding all the AI settings a Client
      # needs. Passed explicitly to every AI service constructor — no
      # module-level globals.
      #
      # Fields:
      #   client         - optional callable; when set, bypasses HTTP.
      #                    Signature: #call(messages:, temperature:) -> Hash
      #   endpoint       - HTTPS URL of the chat completions endpoint
      #   api_key        - API key (used as Bearer or api-key header)
      #   model          - model name passed in the request body
      #   auth_style     - :bearer or :api_key
      #   system_context - optional domain context string that services
      #                    append to their system prompts
      Config = Struct.new(
        :client,
        :endpoint,
        :api_key,
        :model,
        :auth_style,
        :system_context,
        keyword_init: true,
      ) do
        def enabled?
          return true if client
          return false if endpoint.nil? || endpoint.to_s.empty?
          return false if api_key.nil? || api_key.to_s.empty?

          true
        end
      end
    end
  end
end
