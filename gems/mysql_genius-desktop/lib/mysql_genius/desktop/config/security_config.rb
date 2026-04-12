# frozen_string_literal: true

module MysqlGenius
  module Desktop
    class Config
      class SecurityConfig < Struct.new(:blocked_tables, :masked_column_patterns, :default_columns, keyword_init: true)
        DEFAULTS = { blocked_tables: [], masked_column_patterns: [], default_columns: {} }.freeze

        class << self
          def from_hash(hash)
            hash = hash.transform_keys(&:to_sym)
            merged = DEFAULTS.merge(hash.compact)
            new(**merged)
          end
        end
      end
    end
  end
end
