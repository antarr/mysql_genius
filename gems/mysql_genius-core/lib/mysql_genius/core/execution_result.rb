# frozen_string_literal: true

module MysqlGenius
  module Core
    # Immutable frozen value object returned from Core::QueryRunner#run.
    # Contains the executed columns and (possibly masked) rows plus runtime
    # metrics: row count, wall-clock execution time in milliseconds, and a
    # truncated flag indicating whether the row count reached the applied
    # LIMIT.
    #
    # This is distinct from Core::Result (which models a plain query result
    # shape) because QueryRunner returns runtime metadata that plain results
    # don't carry.
    class ExecutionResult
      attr_reader :columns, :rows, :row_count, :execution_time_ms, :truncated

      def initialize(columns:, rows:, execution_time_ms:, truncated:)
        @columns = columns.freeze
        @rows = rows.freeze
        @row_count = rows.length
        @execution_time_ms = execution_time_ms
        @truncated = truncated
        freeze
      end
    end
  end
end
