# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Builds formatted schema-description strings for AI prompt context.
      # Used by SchemaReview, RewriteQuery, IndexAdvisor, and MigrationRisk.
      #
      # Consolidates the ~10 lines of schema description logic that were
      # duplicated across 4 AI features in the Rails adapter's
      # app/controllers/concerns/mysql_genius/ai_features.rb.
      class SchemaContextBuilder
        def initialize(connection)
          @connection = connection
        end

        # Returns a formatted multi-line string describing the given tables.
        #
        # detail:
        #   :basic             — name, row count, primary key, columns, indexes
        #   :with_cardinality  — adds information_schema.STATISTICS cardinality per index
        def call(tables, detail: :basic)
          Array(tables).filter_map { |t| describe_table(t, detail: detail) }.join("\n\n")
        end

        private

        def describe_table(table, detail:)
          return unless @connection.tables.include?(table)

          cols = @connection.columns_for(table).map do |c|
            parts = ["#{c.name} #{c.sql_type}"]
            parts << "NOT NULL" unless c.null
            parts << "DEFAULT #{c.default}" if c.default
            parts.join(" ")
          end

          pk = @connection.primary_key(table)
          indexes = @connection.indexes_for(table).map do |idx|
            "#{"UNIQUE " if idx.unique}INDEX #{idx.name} (#{idx.columns.join(", ")})"
          end

          row_count = fetch_row_count(table)

          parts = [
            "Table: #{table} (~#{row_count || "unknown"} rows)",
            "Primary Key: #{pk || "NONE"}",
            "Columns: #{cols.join(", ")}",
            "Indexes: #{indexes.any? ? indexes.join(", ") : "NONE"}",
          ]

          parts << index_cardinality(table) if detail == :with_cardinality

          parts.join("\n")
        end

        def fetch_row_count(table)
          sql = "SELECT TABLE_ROWS FROM information_schema.tables " \
            "WHERE table_schema = #{@connection.quote(@connection.current_database)} " \
            "AND table_name = #{@connection.quote(table)}"
          result = @connection.exec_query(sql)
          result.rows.first&.first
        rescue StandardError
          nil
        end

        def index_cardinality(table)
          sql = "SELECT INDEX_NAME, COLUMN_NAME, CARDINALITY, SEQ_IN_INDEX " \
            "FROM information_schema.STATISTICS " \
            "WHERE TABLE_SCHEMA = #{@connection.quote(@connection.current_database)} " \
            "AND TABLE_NAME = #{@connection.quote(table)} " \
            "ORDER BY INDEX_NAME, SEQ_IN_INDEX"
          result = @connection.exec_query(sql)
          stats = result.rows.map { |r| "#{r[0]}.#{r[1]}: cardinality=#{r[2]}" }
          "Cardinality: #{stats.join(", ")}"
        rescue StandardError
          "Cardinality: (unavailable)"
        end
      end
    end
  end
end
