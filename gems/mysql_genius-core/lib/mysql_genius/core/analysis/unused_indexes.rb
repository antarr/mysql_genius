# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Queries performance_schema.table_io_waits_summary_by_index_usage
      # joined with information_schema.tables to find indexes with zero
      # reads but non-zero row counts in their parent table. Returns hashes
      # with a ready-to-run DROP INDEX statement per result.
      #
      # Skips the PRIMARY index (should never be dropped) and anonymous
      # rows (where INDEX_NAME IS NULL). Raises if performance_schema is
      # unavailable.
      class UnusedIndexes
        def initialize(connection)
          @connection = connection
        end

        def call
          db_name = @connection.current_database

          result = @connection.exec_query(<<~SQL)
            SELECT
              s.OBJECT_SCHEMA AS table_schema,
              s.OBJECT_NAME AS table_name,
              s.INDEX_NAME AS index_name,
              s.COUNT_READ AS `reads`,
              s.COUNT_WRITE AS `writes`,
              t.TABLE_ROWS AS table_rows
            FROM performance_schema.table_io_waits_summary_by_index_usage s
            JOIN information_schema.tables t
              ON t.TABLE_SCHEMA = s.OBJECT_SCHEMA AND t.TABLE_NAME = s.OBJECT_NAME
            WHERE s.OBJECT_SCHEMA = #{@connection.quote(db_name)}
              AND s.INDEX_NAME IS NOT NULL
              AND s.INDEX_NAME != 'PRIMARY'
              AND s.COUNT_READ = 0
              AND t.TABLE_ROWS > 0
            ORDER BY s.COUNT_WRITE DESC
          SQL

          result.to_hashes.map do |row|
            table = row["table_name"] || row["TABLE_NAME"]
            index_name = row["index_name"] || row["INDEX_NAME"]
            {
              table: table,
              index_name: index_name,
              reads: (row["reads"] || row["READS"] || 0).to_i,
              writes: (row["writes"] || row["WRITES"] || 0).to_i,
              table_rows: (row["table_rows"] || row["TABLE_ROWS"] || 0).to_i,
              drop_sql: "ALTER TABLE `#{table}` DROP INDEX `#{index_name}`;",
            }
          end
        end
      end
    end
  end
end
