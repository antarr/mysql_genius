# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Queries information_schema.tables for data/index/fragmentation metrics
      # per BASE TABLE in the current database, plus an exact SELECT COUNT(*)
      # for each table. Returns an array of hashes suitable for JSON rendering.
      #
      # Takes a Core::Connection. No configuration required — the current
      # database is read from connection.current_database.
      class TableSizes
        def initialize(connection)
          @connection = connection
        end

        def call
          db_name = @connection.current_database

          result = @connection.exec_query(<<~SQL)
            SELECT
              table_name,
              engine,
              table_collation,
              auto_increment,
              update_time,
              ROUND(data_length / 1024 / 1024, 2) AS data_mb,
              ROUND(index_length / 1024 / 1024, 2) AS index_mb,
              ROUND((data_length + index_length) / 1024 / 1024, 2) AS total_mb,
              ROUND(data_free / 1024 / 1024, 2) AS fragmented_mb
            FROM information_schema.tables
            WHERE table_schema = #{@connection.quote(db_name)}
              AND table_type = 'BASE TABLE'
            ORDER BY (data_length + index_length) DESC
          SQL

          result.to_hashes.map do |row|
            table_name = row["table_name"] || row["TABLE_NAME"]
            row_count = begin
              @connection.select_value("SELECT COUNT(*) FROM #{@connection.quote_table_name(table_name)}")
            rescue StandardError
              nil
            end

            total_mb = (row["total_mb"] || 0).to_f
            fragmented_mb = (row["fragmented_mb"] || 0).to_f

            {
              table: table_name,
              rows: row_count,
              engine: row["engine"] || row["ENGINE"],
              collation: row["table_collation"] || row["TABLE_COLLATION"],
              auto_increment: row["auto_increment"] || row["AUTO_INCREMENT"],
              updated_at: row["update_time"] || row["UPDATE_TIME"],
              data_mb: (row["data_mb"] || 0).to_f,
              index_mb: (row["index_mb"] || 0).to_f,
              total_mb: total_mb,
              fragmented_mb: fragmented_mb,
              needs_optimize: total_mb.positive? && fragmented_mb > (total_mb * 0.1),
            }
          end
        end
      end
    end
  end
end
