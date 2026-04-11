# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Queries performance_schema.events_statements_summary_by_digest for
      # the top statements by a given sort dimension, excluding noise
      # (internal schema queries, EXPLAIN, SHOW, SET STATEMENT, etc.).
      # Returns an array of per-digest hashes with call counts, timing
      # percentiles, row examine/sent ratios, and temp-table metadata.
      #
      # If performance_schema is not enabled, the underlying exec_query
      # call will raise — the caller decides how to render that.
      class QueryStats
        VALID_SORTS = ["total_time", "avg_time", "calls", "rows_examined"].freeze
        MAX_LIMIT = 50

        def initialize(connection)
          @connection = connection
        end

        def call(sort: "total_time", limit: MAX_LIMIT)
          order_clause = order_clause_for(sort)
          effective_limit = limit.to_i.clamp(1, MAX_LIMIT)

          result = @connection.exec_query(build_sql(order_clause, effective_limit))
          result.to_hashes.map { |row| transform(row) }
        end

        private

        def order_clause_for(sort)
          case sort
          when "total_time"    then "SUM_TIMER_WAIT DESC"
          when "avg_time"      then "AVG_TIMER_WAIT DESC"
          when "calls"         then "COUNT_STAR DESC"
          when "rows_examined" then "SUM_ROWS_EXAMINED DESC"
          else "SUM_TIMER_WAIT DESC"
          end
        end

        def build_sql(order_clause, limit)
          <<~SQL
            SELECT
              DIGEST_TEXT,
              COUNT_STAR AS calls,
              ROUND(SUM_TIMER_WAIT / 1000000000, 1) AS total_time_ms,
              ROUND(AVG_TIMER_WAIT / 1000000000, 1) AS avg_time_ms,
              ROUND(MAX_TIMER_WAIT / 1000000000, 1) AS max_time_ms,
              SUM_ROWS_EXAMINED AS rows_examined,
              SUM_ROWS_SENT AS rows_sent,
              SUM_CREATED_TMP_DISK_TABLES AS tmp_disk_tables,
              SUM_SORT_ROWS AS sort_rows,
              FIRST_SEEN,
              LAST_SEEN
            FROM performance_schema.events_statements_summary_by_digest
            WHERE SCHEMA_NAME = #{@connection.quote(@connection.current_database)}
              AND DIGEST_TEXT IS NOT NULL
              AND DIGEST_TEXT NOT LIKE 'EXPLAIN%'
              AND DIGEST_TEXT NOT LIKE '%`information_schema`%'
              AND DIGEST_TEXT NOT LIKE '%`performance_schema`%'
              AND DIGEST_TEXT NOT LIKE '%information_schema.%'
              AND DIGEST_TEXT NOT LIKE '%performance_schema.%'
              AND DIGEST_TEXT NOT LIKE 'SHOW %'
              AND DIGEST_TEXT NOT LIKE 'SET STATEMENT %'
              AND DIGEST_TEXT NOT LIKE 'SELECT VERSION ( )%'
              AND DIGEST_TEXT NOT LIKE 'SELECT @@%'
            ORDER BY #{order_clause}
            LIMIT #{limit}
          SQL
        end

        def transform(row)
          digest = (row["DIGEST_TEXT"] || row["digest_text"] || "").to_s
          calls = (row["calls"] || row["CALLS"] || 0).to_i
          rows_examined = (row["rows_examined"] || row["ROWS_EXAMINED"] || 0).to_i
          rows_sent = (row["rows_sent"] || row["ROWS_SENT"] || 0).to_i

          {
            sql: truncate(digest, 500),
            calls: calls,
            total_time_ms: (row["total_time_ms"] || 0).to_f,
            avg_time_ms: (row["avg_time_ms"] || 0).to_f,
            max_time_ms: (row["max_time_ms"] || 0).to_f,
            rows_examined: rows_examined,
            rows_sent: rows_sent,
            rows_ratio: rows_sent.positive? ? (rows_examined.to_f / rows_sent).round(1) : 0,
            tmp_disk_tables: (row["tmp_disk_tables"] || row["TMP_DISK_TABLES"] || 0).to_i,
            sort_rows: (row["sort_rows"] || row["SORT_ROWS"] || 0).to_i,
            first_seen: row["FIRST_SEEN"] || row["first_seen"],
            last_seen: row["LAST_SEEN"] || row["last_seen"],
          }
        end

        def truncate(string, max)
          return string if string.length <= max

          "#{string[0, max - 3]}..."
        end
      end
    end
  end
end
