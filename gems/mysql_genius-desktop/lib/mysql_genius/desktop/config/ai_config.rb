# frozen_string_literal: true

module MysqlGenius
  module Desktop
    class Config
      class AiConfig < Struct.new(
        :enabled,
        :endpoint,
        :api_key,
        :model,
        :auth_style,
        :system_context,
        :domain_context,
        keyword_init: true,
      )
        DEFAULTS = {
          enabled: nil,
          endpoint: nil,
          api_key: nil,
          model: "",
          auth_style: :bearer,
          system_context: "",
          domain_context: "",
        }.freeze

        class << self
          def from_hash(hash)
            hash = hash.transform_keys(&:to_sym)
            hash[:auth_style] = hash[:auth_style].to_sym if hash[:auth_style].is_a?(String)
            new(**DEFAULTS.merge(hash))
          end
        end

        def enabled?
          return false if enabled == false
          return false if endpoint.nil? || endpoint.to_s.empty?
          return false if api_key.nil? || api_key.to_s.empty?

          true
        end
      end
    end
  end
end
