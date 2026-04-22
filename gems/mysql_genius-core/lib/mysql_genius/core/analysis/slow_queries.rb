# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Queries performance_schema.events_statements_history_long for statements
      # that exceeded a duration threshold. Returns individual statement events,
      # not per-digest aggregates (for aggregates see Core::Analysis::QueryStats).
      #
      # This provides zero-dependency slow-query visibility — no Redis, no
      # MySQL slow-query-log file access required. The ring buffer is global
      # across threads (default size: 10,000 rows, tunable via the server
      # variable `performance_schema_events_statements_history_long_size`).
      #
      # Availability:
      #   - performance_schema must be compiled in (it is, on every official
      #     MySQL/MariaDB build) and not explicitly disabled.
      #   - The `events_statements_history_long` consumer must be enabled.
      #     On MySQL 8.0+ it's on by default. On 5.7 and some managed MySQL
      #     services it may be off. Call #availability to check, or #call
      #     which returns an unavailable Result with an actionable message.
      #
      # Output: #call returns a Result struct with:
      #   - available?  true if queries were retrieved
      #   - reason      human-readable explanation when not available
      #   - queries     array of hashes, each with sql/digest/duration_ms/etc.
      class SlowQueries
        DEFAULT_LIMIT = 200
        DEFAULT_THRESHOLD_MS = 250
        MS_TO_PICOSECONDS = 1_000_000_000

        # Upper bound on SQL_TEXT and DIGEST_TEXT lengths in the returned hashes.
        # performance_schema itself truncates SQL_TEXT at
        # performance_schema_max_sql_text_length (default 1024 bytes), so this
        # is belt-and-suspenders for clients that don't tolerate huge payloads.
        MAX_SQL_LENGTH = 10_000
        MAX_DIGEST_TEXT_LENGTH = 2_000

        Result = Struct.new(:available, :reason, :queries, keyword_init: true) do
          def available?
            available
          end
        end

        def initialize(connection, threshold_ms: DEFAULT_THRESHOLD_MS, limit: DEFAULT_LIMIT)
          @connection = connection
          @threshold_ms = threshold_ms.to_f
          @limit = limit.to_i.clamp(1, 1000)
        end

        def call
          availability = check_availability
          return availability unless availability.available?

          rows = @connection.exec_query(build_sql).to_hashes
          Result.new(available: true, reason: nil, queries: rows.map { |r| transform(r) })
        rescue StandardError => e
          Result.new(available: false, reason: "performance_schema query failed: #{e.message}", queries: [])
        end

        # Public availability probe. Controllers / capability helpers use this
        # to decide whether to surface the slow-query panel at all.
        def availability
          check_availability
        end

        private

        def check_availability
          result = @connection.exec_query(
            "SELECT ENABLED FROM performance_schema.setup_consumers " \
              "WHERE NAME = 'events_statements_history_long'",
          )
          row = result.rows.first
          if row.nil?
            return Result.new(
              available: false,
              reason: "The events_statements_history_long consumer is not present in this MySQL's performance_schema. " \
                "This typically means performance_schema is disabled at the server level " \
                "(performance_schema = OFF in my.cnf).",
              queries: [],
            )
          end

          enabled = row.first.to_s.upcase == "YES"
          return Result.new(available: true, reason: nil, queries: []) if enabled

          Result.new(
            available: false,
            reason: "The events_statements_history_long consumer is disabled. Enable with: " \
              "UPDATE performance_schema.setup_consumers SET ENABLED = 'YES' " \
              "WHERE NAME = 'events_statements_history_long';",
            queries: [],
          )
        rescue StandardError => e
          Result.new(
            available: false,
            reason: "performance_schema unreachable: #{e.message}. " \
              "Some managed MySQL services restrict access to performance_schema tables.",
            queries: [],
          )
        end

        def build_sql
          threshold_ps = (@threshold_ms * MS_TO_PICOSECONDS).to_i
          <<~SQL
            SELECT
              DIGEST,
              DIGEST_TEXT,
              SQL_TEXT,
              TIMER_WAIT,
              CURRENT_SCHEMA,
              ROWS_EXAMINED,
              ROWS_SENT,
              NO_INDEX_USED,
              CREATED_TMP_TABLES,
              CREATED_TMP_DISK_TABLES,
              ERRORS,
              MYSQL_ERRNO,
              END_EVENT_ID
            FROM performance_schema.events_statements_history_long
            WHERE TIMER_WAIT > #{threshold_ps}
              AND DIGEST_TEXT IS NOT NULL
              AND DIGEST_TEXT NOT LIKE 'EXPLAIN%'
              AND DIGEST_TEXT NOT LIKE '%`information_schema`%'
              AND DIGEST_TEXT NOT LIKE '%`performance_schema`%'
              AND DIGEST_TEXT NOT LIKE '%information_schema.%'
              AND DIGEST_TEXT NOT LIKE '%performance_schema.%'
              AND DIGEST_TEXT NOT LIKE 'SHOW %'
              AND DIGEST_TEXT NOT LIKE 'SET %'
              AND DIGEST_TEXT NOT LIKE 'USE %'
              AND DIGEST_TEXT NOT LIKE 'COMMIT%'
              AND DIGEST_TEXT NOT LIKE 'ROLLBACK%'
              AND DIGEST_TEXT NOT LIKE 'BEGIN%'
              AND DIGEST_TEXT NOT LIKE 'START TRANSACTION%'
            ORDER BY TIMER_WAIT DESC
            LIMIT #{@limit}
          SQL
        end

        def transform(row)
          digest_text = fetch(row, "DIGEST_TEXT").to_s
          sql_text = fetch(row, "SQL_TEXT").to_s
          sql = sql_text.empty? ? digest_text : sql_text
          timer_wait = fetch(row, "TIMER_WAIT").to_i

          {
            sql: truncate(sql, MAX_SQL_LENGTH),
            digest_text: truncate(digest_text, MAX_DIGEST_TEXT_LENGTH),
            digest: fetch(row, "DIGEST").to_s,
            duration_ms: (timer_wait.to_f / MS_TO_PICOSECONDS).round(2),
            rows_examined: fetch(row, "ROWS_EXAMINED").to_i,
            rows_sent: fetch(row, "ROWS_SENT").to_i,
            rows_ratio: rows_ratio(fetch(row, "ROWS_EXAMINED"), fetch(row, "ROWS_SENT")),
            no_index_used: truthy?(fetch(row, "NO_INDEX_USED")),
            tmp_tables: fetch(row, "CREATED_TMP_TABLES").to_i,
            tmp_disk_tables: fetch(row, "CREATED_TMP_DISK_TABLES").to_i,
            errors: fetch(row, "ERRORS").to_i,
            mysql_errno: fetch(row, "MYSQL_ERRNO").to_i,
            schema: fetch(row, "CURRENT_SCHEMA"),
            # The frontend's existing Redis flow serializes a timestamp field.
            # performance_schema doesn't store a wall-clock time per event
            # (only picoseconds since server start via TIMER_END), so we leave
            # timestamp as nil here and let the caller enrich if desired.
            timestamp: nil,
            source: "performance_schema",
          }
        end

        # Adapters differ on row hash key case (mysql2 downcases, trilogy preserves).
        # Try both common forms.
        def fetch(row, column)
          row[column] || row[column.downcase] || row[column.to_sym] || row[column.downcase.to_sym]
        end

        def rows_ratio(examined, sent)
          examined = examined.to_i
          sent = sent.to_i
          return 0 if sent.zero?

          (examined.to_f / sent).round(1)
        end

        def truthy?(value)
          case value
          when true, 1, "1", "YES", "yes", :yes then true
          else false
          end
        end

        def truncate(string, max)
          string = string.to_s
          return string if string.length <= max

          "#{string[0, max - 3]}..."
        end
      end
    end
  end
end
