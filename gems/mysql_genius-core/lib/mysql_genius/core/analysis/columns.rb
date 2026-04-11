# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Service class for the Rails engine's GET /columns action and its
      # Phase 2b sidecar equivalent. Takes a Core::Connection and the
      # relevant configuration; returns a tagged Result struct that
      # adapters map to HTTP responses.
      #
      # Each status maps 1:1 to an HTTP status code:
      #   :ok        → 200 with columns: array
      #   :blocked   → 403 with error_message:
      #   :not_found → 404 with error_message:
      #
      # The adapter reads result.status and dispatches accordingly.
      class Columns
        Result = Struct.new(:status, :columns, :error_message, keyword_init: true)

        def initialize(connection, blocked_tables:, masked_column_patterns:, default_columns:)
          @connection = connection
          @blocked_tables = blocked_tables
          @masked_column_patterns = masked_column_patterns
          @default_columns = default_columns
        end

        def call(table:)
          return blocked_result(table)   if @blocked_tables.include?(table)
          return not_found_result(table) unless @connection.tables.include?(table)

          defaults = @default_columns[table] || []
          visible = @connection.columns_for(table).reject do |col|
            SqlValidator.masked_column?(col.name, @masked_column_patterns)
          end
          formatted = visible.map do |col|
            {
              name: col.name,
              type: col.type.to_s,
              default: defaults.empty? || defaults.include?(col.name),
            }
          end

          Result.new(status: :ok, columns: formatted)
        end

        private

        def blocked_result(table)
          Result.new(
            status: :blocked,
            error_message: "Table '#{table}' is not available for querying.",
          )
        end

        def not_found_result(table)
          Result.new(
            status: :not_found,
            error_message: "Table '#{table}' does not exist.",
          )
        end
      end
    end
  end
end
