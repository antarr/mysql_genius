# frozen_string_literal: true

module MysqlGenius
  module Desktop
    class Config
      class QueryConfig < Struct.new(:default_row_limit, :max_row_limit, :timeout_seconds, keyword_init: true)
        DEFAULTS = { default_row_limit: 100, max_row_limit: 10_000, timeout_seconds: 10 }.freeze

        class << self
          def from_hash(hash)
            hash = hash.transform_keys(&:to_sym)
            new(**DEFAULTS.merge(hash))
          end
        end

        def query_timeout_ms
          timeout_seconds * 1000
        end
      end
    end
  end
end
