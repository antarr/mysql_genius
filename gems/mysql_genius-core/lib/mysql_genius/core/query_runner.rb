# frozen_string_literal: true

require "set"

module MysqlGenius
  module Core
    # Runs SELECT queries against a Core::Connection with SQL validation,
    # row-limit application, timeout hints (MySQL or MariaDB flavor), and
    # column masking. Returns a Core::ExecutionResult on success or raises
    # a specific error class on failure.
    #
    # Does NOT handle audit logging — the caller (Rails concern or future
    # desktop sidecar) is responsible for recording successful queries and
    # errors using whatever logger it owns.
    class QueryRunner
      class Rejected < Core::Error; end
      class Timeout < Core::Error; end

      TIMEOUT_PATTERNS = [
        "max_statement_time",
        "max_execution_time",
        "Query execution was interrupted",
      ].freeze

      def initialize(connection, config)
        @connection = connection
        @config = config
      end

      def run(sql, row_limit:)
        validation_error = SqlValidator.validate(
          sql,
          blocked_tables: @config.blocked_tables,
          connection: @connection,
        )
        raise Rejected, validation_error if validation_error

        limited = SqlValidator.apply_row_limit(sql, row_limit)
        timed = apply_timeout_hint(limited)

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = begin
          @connection.exec_query(timed)
        rescue StandardError => e
          raise Timeout, e.message if timeout_error?(e)

          raise
        end
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

        masked_rows = mask_rows(result)

        ExecutionResult.new(
          columns: result.columns,
          rows: masked_rows,
          execution_time_ms: duration_ms,
          truncated: masked_rows.length >= row_limit,
        )
      end

      private

      def apply_timeout_hint(sql)
        if mariadb?
          timeout_seconds = @config.query_timeout_ms / 1000
          "SET STATEMENT max_statement_time=#{timeout_seconds} FOR #{sql}"
        else
          sql.sub(/\bSELECT\b/i, "SELECT /*+ MAX_EXECUTION_TIME(#{@config.query_timeout_ms}) */")
        end
      end

      def mariadb?
        @connection.server_version.mariadb?
      end

      def mask_rows(result)
        mask_indices = result.columns.each_with_index.select do |name, _i|
          SqlValidator.masked_column?(name, @config.masked_column_patterns)
        end.map { |(_name, i)| i }.to_set

        return result.rows if mask_indices.empty?

        result.rows.map do |row|
          row.each_with_index.map { |value, i| mask_indices.include?(i) ? "[REDACTED]" : value }
        end
      end

      def timeout_error?(exception)
        msg = exception.message
        TIMEOUT_PATTERNS.any? { |pattern| msg.include?(pattern) }
      end
    end
  end
end
