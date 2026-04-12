# frozen_string_literal: true

module MysqlGenius
  module Desktop
    class Config
      class InvalidConfigError < StandardError; end

      class MysqlConfig < Struct.new(:host, :port, :username, :password, :database, :tls_mode, keyword_init: true)
        DEFAULTS = { port: 3306, password: "", tls_mode: "preferred" }.freeze
        REQUIRED = [:host, :username, :database].freeze

        class << self
          def from_hash(hash)
            hash = hash.transform_keys(&:to_sym)
            missing = REQUIRED - hash.keys
            raise Config::InvalidConfigError, "mysql: required fields missing: #{missing.join(", ")}" if missing.any?

            new(**DEFAULTS.merge(hash))
          end
        end
      end
    end
  end
end
