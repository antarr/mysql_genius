# frozen_string_literal: true

module MysqlGenius
  module Core
    # Forward declaration so Config can be namespaced under QueryRunner.
    # The full QueryRunner class is defined in query_runner.rb.
    class QueryRunner
      Config = Struct.new(
        :blocked_tables,
        :masked_column_patterns,
        :query_timeout_ms,
        keyword_init: true,
      ) do
        def initialize(*)
          super
          freeze
        end
      end
    end
  end
end
