module MysqlGenius
  class QueriesController < BaseController
    def index
      @featured_tables = if mysql_genius_config.featured_tables.any?
                           mysql_genius_config.featured_tables.sort
                         else
                           queryable_tables.sort
                         end
      @all_tables = queryable_tables.sort
      @ai_enabled = mysql_genius_config.ai_enabled?
    end

    def slow_queries
      unless mysql_genius_config.redis_url.present?
        return render json: { error: "Slow query monitoring is not configured." }, status: :not_found
      end

      redis = Redis.new(url: mysql_genius_config.redis_url)
      key = SlowQueryMonitor.redis_key
      raw = redis.lrange(key, 0, 199)
      queries = raw.map { |entry| JSON.parse(entry) rescue nil }.compact
      render json: queries
    rescue => e
      render json: [], status: :ok
    end

    def columns
      table = params[:table]
      if mysql_genius_config.blocked_tables.include?(table)
        return render json: { error: "Table '#{table}' is not available for querying." }, status: :forbidden
      end

      unless ActiveRecord::Base.connection.tables.include?(table)
        return render json: { error: "Table '#{table}' does not exist." }, status: :not_found
      end

      defaults = mysql_genius_config.default_columns[table] || []
      cols = ActiveRecord::Base.connection.columns(table).reject { |c| masked_column?(c.name) }.map do |c|
        { name: c.name, type: c.type.to_s, default: defaults.empty? || defaults.include?(c.name) }
      end
      render json: cols
    end

    def execute
      sql = params[:sql].to_s.strip
      row_limit = if params[:row_limit].present?
                    [[params[:row_limit].to_i, 1].max, mysql_genius_config.max_row_limit].min
                  else
                    mysql_genius_config.default_row_limit
                  end

      error = validate_sql(sql)
      if error
        audit(:rejection, sql: sql, reason: error)
        return render json: { error: error }, status: :unprocessable_entity
      end

      limited_sql = apply_row_limit(sql, row_limit)
      timed_sql = apply_timeout_hint(limited_sql)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        results = ActiveRecord::Base.connection.exec_query(timed_sql)
        execution_time_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)

        columns = results.columns
        rows = results.rows.map do |row|
          row.each_with_index.map do |value, i|
            masked_column?(columns[i]) ? "[REDACTED]" : value
          end
        end

        truncated = rows.length >= row_limit

        audit(:query, sql: sql, execution_time_ms: execution_time_ms, row_count: rows.length)

        render json: {
          columns: columns,
          rows: rows,
          row_count: rows.length,
          execution_time_ms: execution_time_ms,
          truncated: truncated
        }
      rescue ActiveRecord::StatementInvalid => e
        if timeout_error?(e)
          audit(:error, sql: sql, error: "Query timeout")
          render json: { error: "Query exceeded the #{mysql_genius_config.query_timeout_ms / 1000} second timeout limit.", timeout: true }, status: :unprocessable_entity
        else
          audit(:error, sql: sql, error: e.message)
          render json: { error: "Query error: #{e.message.split(':').last.strip}" }, status: :unprocessable_entity
        end
      end
    end

    def explain
      sql = params[:sql].to_s.strip
      skip_validation = params[:from_slow_query] == "true"

      unless skip_validation
        error = validate_sql(sql)
        return render json: { error: error }, status: :unprocessable_entity if error
      end

      # Reject truncated SQL (captured slow queries are capped at 2000 chars)
      unless sql.match?(/\)\s*$/) || sql.match?(/\w\s*$/) || sql.match?(/['"`]\s*$/) || sql.match?(/\d\s*$/)
        return render json: { error: "This query appears to be truncated and cannot be explained." }, status: :unprocessable_entity
      end

      explain_sql = "EXPLAIN #{sql.gsub(/;\s*\z/, '')}"
      results = ActiveRecord::Base.connection.exec_query(explain_sql)

      render json: { columns: results.columns, rows: results.rows }
    rescue ActiveRecord::StatementInvalid => e
      render json: { error: "Explain error: #{e.message.split(':').last.strip}" }, status: :unprocessable_entity
    end

    def suggest
      unless mysql_genius_config.ai_enabled?
        return render json: { error: "AI features are not configured." }, status: :not_found
      end

      prompt = params[:prompt].to_s.strip
      return render json: { error: "Please describe what you want to query." }, status: :unprocessable_entity if prompt.blank?

      result = AiSuggestionService.new.call(prompt, queryable_tables)
      sql = sanitize_ai_sql(result["sql"].to_s)
      render json: { sql: sql, explanation: result["explanation"] }
    rescue StandardError => e
      render json: { error: "AI suggestion failed: #{e.message}" }, status: :unprocessable_entity
    end

    def optimize
      unless mysql_genius_config.ai_enabled?
        return render json: { error: "AI features are not configured." }, status: :not_found
      end

      sql = params[:sql].to_s.strip
      explain_rows = Array(params[:explain_rows]).map { |row| row.respond_to?(:values) ? row.values : Array(row) }

      if sql.blank? || explain_rows.blank?
        return render json: { error: "SQL and EXPLAIN output are required." }, status: :unprocessable_entity
      end

      result = AiOptimizationService.new.call(sql, explain_rows, queryable_tables)
      render json: result
    rescue StandardError => e
      render json: { error: "Optimization failed: #{e.message}" }, status: :unprocessable_entity
    end

    def duplicate_indexes
      connection = ActiveRecord::Base.connection
      duplicates = []

      queryable_tables.each do |table|
        indexes = connection.indexes(table)
        next if indexes.size < 2

        indexes.each do |idx|
          indexes.each do |other|
            next if idx.name == other.name
            # idx is duplicate if its columns are a left-prefix of other's columns
            if idx.columns.size <= other.columns.size &&
               other.columns.first(idx.columns.size) == idx.columns &&
               !(idx.unique && !other.unique) # don't drop a unique index covered by a non-unique one
              duplicates << {
                table: table,
                duplicate_index: idx.name,
                duplicate_columns: idx.columns,
                covered_by_index: other.name,
                covered_by_columns: other.columns,
                unique: idx.unique
              }
            end
          end
        end
      end

      # Deduplicate (A covers B and B covers A when columns are identical — keep only one)
      seen = Set.new
      duplicates = duplicates.reject do |d|
        key = [d[:table], [d[:duplicate_index], d[:covered_by_index]].sort].flatten.join(":")
        seen.include?(key) ? true : (seen.add(key); false)
      end

      render json: duplicates
    end

    def table_sizes
      connection = ActiveRecord::Base.connection
      db_name = connection.current_database

      results = connection.exec_query(<<~SQL)
        SELECT
          table_name,
          table_rows,
          ROUND(data_length / 1024 / 1024, 2) AS data_mb,
          ROUND(index_length / 1024 / 1024, 2) AS index_mb,
          ROUND((data_length + index_length) / 1024 / 1024, 2) AS total_mb,
          ROUND(data_free / 1024 / 1024, 2) AS fragmented_mb
        FROM information_schema.tables
        WHERE table_schema = #{connection.quote(db_name)}
          AND table_type = 'BASE TABLE'
        ORDER BY (data_length + index_length) DESC
      SQL

      tables = results.map do |row|
        {
          table: row["table_name"] || row["TABLE_NAME"],
          rows: row["table_rows"] || row["TABLE_ROWS"],
          data_mb: row["data_mb"].to_f,
          index_mb: row["index_mb"].to_f,
          total_mb: row["total_mb"].to_f,
          fragmented_mb: row["fragmented_mb"].to_f
        }
      end

      render json: tables
    end

    def query_stats
      connection = ActiveRecord::Base.connection
      sort = %w[total_time avg_time calls rows_examined].include?(params[:sort]) ? params[:sort] : "total_time"

      order_clause = case sort
                     when "total_time"    then "SUM_TIMER_WAIT DESC"
                     when "avg_time"      then "AVG_TIMER_WAIT DESC"
                     when "calls"         then "COUNT_STAR DESC"
                     when "rows_examined" then "SUM_ROWS_EXAMINED DESC"
                     end

      results = connection.exec_query(<<~SQL)
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
        WHERE SCHEMA_NAME = #{connection.quote(connection.current_database)}
          AND DIGEST_TEXT IS NOT NULL
          AND DIGEST_TEXT NOT LIKE 'EXPLAIN%'
        ORDER BY #{order_clause}
        LIMIT 50
      SQL

      queries = results.map do |row|
        digest = row["DIGEST_TEXT"] || row["digest_text"] || ""
        calls = (row["calls"] || row["CALLS"] || 0).to_i
        rows_examined = (row["rows_examined"] || row["ROWS_EXAMINED"] || 0).to_i
        rows_sent = (row["rows_sent"] || row["ROWS_SENT"] || 0).to_i
        {
          sql: digest.truncate(500),
          calls: calls,
          total_time_ms: row["total_time_ms"].to_f,
          avg_time_ms: row["avg_time_ms"].to_f,
          max_time_ms: row["max_time_ms"].to_f,
          rows_examined: rows_examined,
          rows_sent: rows_sent,
          rows_ratio: rows_sent > 0 ? (rows_examined.to_f / rows_sent).round(1) : 0,
          tmp_disk_tables: (row["tmp_disk_tables"] || row["TMP_DISK_TABLES"] || 0).to_i,
          sort_rows: (row["sort_rows"] || row["SORT_ROWS"] || 0).to_i,
          first_seen: row["FIRST_SEEN"] || row["first_seen"],
          last_seen: row["LAST_SEEN"] || row["last_seen"]
        }
      end

      render json: queries
    rescue ActiveRecord::StatementInvalid => e
      render json: { error: "Query statistics require performance_schema to be enabled. #{e.message.split(':').last.strip}" }, status: :unprocessable_entity
    end

    def unused_indexes
      connection = ActiveRecord::Base.connection
      db_name = connection.current_database

      results = connection.exec_query(<<~SQL)
        SELECT
          s.OBJECT_SCHEMA AS table_schema,
          s.OBJECT_NAME AS table_name,
          s.INDEX_NAME AS index_name,
          s.COUNT_READ AS reads,
          s.COUNT_WRITE AS writes,
          t.TABLE_ROWS AS table_rows
        FROM performance_schema.table_io_waits_summary_by_index_usage s
        JOIN information_schema.tables t
          ON t.TABLE_SCHEMA = s.OBJECT_SCHEMA AND t.TABLE_NAME = s.OBJECT_NAME
        WHERE s.OBJECT_SCHEMA = #{connection.quote(db_name)}
          AND s.INDEX_NAME IS NOT NULL
          AND s.INDEX_NAME != 'PRIMARY'
          AND s.COUNT_READ = 0
          AND t.TABLE_ROWS > 0
        ORDER BY s.COUNT_WRITE DESC
      SQL

      indexes = results.map do |row|
        table = row["table_name"] || row["TABLE_NAME"]
        index_name = row["index_name"] || row["INDEX_NAME"]
        {
          table: table,
          index_name: index_name,
          reads: (row["reads"] || row["READS"] || 0).to_i,
          writes: (row["writes"] || row["WRITES"] || 0).to_i,
          table_rows: (row["table_rows"] || row["TABLE_ROWS"] || 0).to_i,
          drop_sql: "ALTER TABLE `#{table}` DROP INDEX `#{index_name}`;"
        }
      end

      render json: indexes
    rescue ActiveRecord::StatementInvalid => e
      render json: { error: "Unused index detection requires performance_schema. #{e.message.split(':').last.strip}" }, status: :unprocessable_entity
    end

    def server_overview
      connection = ActiveRecord::Base.connection

      # Global status variables
      status_rows = connection.exec_query("SHOW GLOBAL STATUS")
      status = {}
      status_rows.each { |r| status[(r["Variable_name"] || r["variable_name"]).to_s] = (r["Value"] || r["value"]).to_s }

      # Global variables
      vars_rows = connection.exec_query("SHOW GLOBAL VARIABLES")
      vars = {}
      vars_rows.each { |r| vars[(r["Variable_name"] || r["variable_name"]).to_s] = (r["Value"] || r["value"]).to_s }

      version = connection.select_value("SELECT VERSION()")
      uptime_seconds = status["Uptime"].to_i

      days = uptime_seconds / 86400
      hours = (uptime_seconds % 86400) / 3600
      minutes = (uptime_seconds % 3600) / 60

      max_conn = vars["max_connections"].to_i
      current_conn = status["Threads_connected"].to_i
      conn_pct = max_conn > 0 ? ((current_conn.to_f / max_conn) * 100).round(1) : 0

      buffer_pool_bytes = vars["innodb_buffer_pool_size"].to_i
      buffer_pool_mb = (buffer_pool_bytes / 1024.0 / 1024.0).round(1)

      # Buffer pool hit rate
      reads = status["Innodb_buffer_pool_read_requests"].to_f
      disk_reads = status["Innodb_buffer_pool_reads"].to_f
      hit_rate = reads > 0 ? (((reads - disk_reads) / reads) * 100).round(2) : 0

      # Tmp tables
      tmp_tables = status["Created_tmp_tables"].to_i
      tmp_disk_tables = status["Created_tmp_disk_tables"].to_i
      tmp_disk_pct = tmp_tables > 0 ? ((tmp_disk_tables.to_f / tmp_tables) * 100).round(1) : 0

      # Slow queries from MySQL's own counter
      slow_queries = status["Slow_queries"].to_i

      # Questions (total queries)
      questions = status["Questions"].to_i
      qps = uptime_seconds > 0 ? (questions.to_f / uptime_seconds).round(1) : 0

      render json: {
        server: {
          version: version,
          uptime: "#{days}d #{hours}h #{minutes}m",
          uptime_seconds: uptime_seconds
        },
        connections: {
          max: max_conn,
          current: current_conn,
          usage_pct: conn_pct,
          threads_running: status["Threads_running"].to_i,
          threads_cached: status["Threads_cached"].to_i,
          threads_created: status["Threads_created"].to_i,
          aborted_connects: status["Aborted_connects"].to_i,
          aborted_clients: status["Aborted_clients"].to_i,
          max_used: status["Max_used_connections"].to_i
        },
        innodb: {
          buffer_pool_mb: buffer_pool_mb,
          buffer_pool_hit_rate: hit_rate,
          buffer_pool_pages_dirty: status["Innodb_buffer_pool_pages_dirty"].to_i,
          buffer_pool_pages_free: status["Innodb_buffer_pool_pages_free"].to_i,
          buffer_pool_pages_total: status["Innodb_buffer_pool_pages_total"].to_i,
          row_lock_waits: status["Innodb_row_lock_waits"].to_i,
          row_lock_time_ms: (status["Innodb_row_lock_time"].to_f).round(0)
        },
        queries: {
          questions: questions,
          qps: qps,
          slow_queries: slow_queries,
          tmp_tables: tmp_tables,
          tmp_disk_tables: tmp_disk_tables,
          tmp_disk_pct: tmp_disk_pct,
          select_full_join: status["Select_full_join"].to_i,
          sort_merge_passes: status["Sort_merge_passes"].to_i
        }
      }
    rescue => e
      render json: { error: "Failed to load server overview: #{e.message}" }, status: :unprocessable_entity
    end

    # --- AI Features ---

    def describe_query
      return ai_not_configured unless mysql_genius_config.ai_enabled?
      sql = params[:sql].to_s.strip
      return render json: { error: "SQL is required." }, status: :unprocessable_entity if sql.blank?

      messages = [
        { role: "system", content: <<~PROMPT },
          You are a MySQL query explainer. Given a SQL query, explain in plain English:
          1. What the query does (tables involved, joins, filters, aggregations)
          2. How data flows through the query
          3. Any subtle behaviors (implicit type casts, NULL handling in NOT IN, DISTINCT effects, etc.)
          4. Potential performance concerns visible from the SQL structure alone
          #{ai_domain_context}
          Respond with JSON: {"explanation": "your plain-English explanation using markdown formatting"}
        PROMPT
        { role: "user", content: sql }
      ]

      result = AiClient.new.chat(messages: messages)
      render json: result
    rescue StandardError => e
      render json: { error: "Explanation failed: #{e.message}" }, status: :unprocessable_entity
    end

    def schema_review
      return ai_not_configured unless mysql_genius_config.ai_enabled?
      table = params[:table].to_s.strip
      connection = ActiveRecord::Base.connection

      tables_to_review = table.present? ? [table] : queryable_tables.first(20)
      schema_desc = tables_to_review.map do |t|
        next unless connection.tables.include?(t)
        cols = connection.columns(t).map { |c| "#{c.name} #{c.sql_type}#{c.null ? '' : ' NOT NULL'}#{c.default ? " DEFAULT #{c.default}" : ''}" }
        indexes = connection.indexes(t).map { |idx| "#{idx.unique ? 'UNIQUE ' : ''}INDEX #{idx.name} (#{idx.columns.join(', ')})" }
        row_count = connection.exec_query("SELECT TABLE_ROWS FROM information_schema.tables WHERE table_schema = #{connection.quote(connection.current_database)} AND table_name = #{connection.quote(t)}").rows.first&.first
        "Table: #{t} (~#{row_count} rows)\nColumns: #{cols.join(', ')}\nIndexes: #{indexes.any? ? indexes.join(', ') : 'NONE'}"
      end.compact.join("\n\n")

      messages = [
        { role: "system", content: <<~PROMPT },
          You are a MySQL schema reviewer. Analyze the following schema and identify anti-patterns and improvement opportunities. Look for:
          - Inappropriate column types (VARCHAR(255) for short values, TEXT where VARCHAR suffices, INT for booleans)
          - Missing indexes on foreign key columns or frequently filtered columns
          - Missing NOT NULL constraints where NULLs are unlikely
          - ENUM columns that should be lookup tables
          - Missing created_at/updated_at timestamps
          - Tables without a PRIMARY KEY
          - Overly wide indexes or redundant indexes
          - Column naming inconsistencies
          #{ai_domain_context}
          Respond with JSON: {"findings": "markdown-formatted findings organized by severity (Critical, Warning, Suggestion). Include specific ALTER TABLE statements where applicable."}
        PROMPT
        { role: "user", content: schema_desc }
      ]

      result = AiClient.new.chat(messages: messages)
      render json: result
    rescue StandardError => e
      render json: { error: "Schema review failed: #{e.message}" }, status: :unprocessable_entity
    end

    def rewrite_query
      return ai_not_configured unless mysql_genius_config.ai_enabled?
      sql = params[:sql].to_s.strip
      return render json: { error: "SQL is required." }, status: :unprocessable_entity if sql.blank?

      schema = build_schema_for_query(sql)

      messages = [
        { role: "system", content: <<~PROMPT },
          You are a MySQL query rewrite expert. Analyze the SQL for anti-patterns and suggest a rewritten version. Look for:
          - SELECT * when specific columns would suffice
          - Correlated subqueries that could be JOINs
          - OR conditions preventing index use (suggest UNION ALL)
          - LIKE '%prefix' patterns (leading wildcard)
          - Implicit type conversions in WHERE clauses
          - NOT IN with NULLable columns (suggest NOT EXISTS)
          - ORDER BY on non-indexed columns with LIMIT
          - Unnecessary DISTINCT
          - Functions on indexed columns in WHERE (e.g., DATE(created_at) instead of range)

          Available schema:
          #{schema}
          #{ai_domain_context}

          Respond with JSON: {"original": "the original SQL", "rewritten": "the improved SQL", "changes": "markdown list of each change and why it helps"}
        PROMPT
        { role: "user", content: sql }
      ]

      result = AiClient.new.chat(messages: messages)
      render json: result
    rescue StandardError => e
      render json: { error: "Rewrite failed: #{e.message}" }, status: :unprocessable_entity
    end

    def index_advisor
      return ai_not_configured unless mysql_genius_config.ai_enabled?
      sql = params[:sql].to_s.strip
      explain_rows = Array(params[:explain_rows]).map { |row| row.respond_to?(:values) ? row.values : Array(row) }
      return render json: { error: "SQL and EXPLAIN output are required." }, status: :unprocessable_entity if sql.blank? || explain_rows.blank?

      connection = ActiveRecord::Base.connection
      tables_in_query = SqlValidator.extract_table_references(sql, connection)

      index_detail = tables_in_query.map do |t|
        indexes = connection.indexes(t).map { |idx| "#{idx.unique ? 'UNIQUE ' : ''}INDEX #{idx.name} (#{idx.columns.join(', ')})" }
        stats = connection.exec_query("SELECT INDEX_NAME, COLUMN_NAME, CARDINALITY, SEQ_IN_INDEX FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = #{connection.quote(connection.current_database)} AND TABLE_NAME = #{connection.quote(t)} ORDER BY INDEX_NAME, SEQ_IN_INDEX")
        cardinality = stats.rows.map { |r| "#{r[0]}.#{r[1]}: cardinality=#{r[2]}" }.join(", ")
        row_count = connection.exec_query("SELECT TABLE_ROWS FROM information_schema.tables WHERE table_schema = #{connection.quote(connection.current_database)} AND table_name = #{connection.quote(t)}").rows.first&.first
        "Table: #{t} (~#{row_count} rows)\nIndexes: #{indexes.any? ? indexes.join('; ') : 'NONE'}\nCardinality: #{cardinality}"
      end.join("\n\n")

      messages = [
        { role: "system", content: <<~PROMPT },
          You are a MySQL index advisor. Given a query, its EXPLAIN output, and current index/cardinality information, suggest optimal indexes. Consider:
          - Composite index column ordering (most selective first, or matching query order)
          - Covering indexes to avoid table lookups
          - Partial indexes for long string columns
          - Write-side costs (if this is a high-write table, note the INSERT/UPDATE overhead)
          - Whether existing indexes could be extended rather than creating new ones
          #{ai_domain_context}

          Respond with JSON: {"indexes": "markdown-formatted recommendations with exact CREATE INDEX statements, rationale for column ordering, and estimated impact. Include any indexes that should be DROPPED as part of the change."}
        PROMPT
        { role: "user", content: "Query:\n#{sql}\n\nEXPLAIN:\n#{explain_rows.map { |r| r.join(' | ') }.join("\n")}\n\nCurrent Indexes:\n#{index_detail}" }
      ]

      result = AiClient.new.chat(messages: messages)
      render json: result
    rescue StandardError => e
      render json: { error: "Index advisor failed: #{e.message}" }, status: :unprocessable_entity
    end

    def anomaly_detection
      return ai_not_configured unless mysql_genius_config.ai_enabled?
      connection = ActiveRecord::Base.connection

      # Gather recent slow queries
      slow_data = []
      if mysql_genius_config.redis_url
        redis = Redis.new(url: mysql_genius_config.redis_url)
        raw = redis.lrange(SlowQueryMonitor.redis_key, 0, 99)
        slow_data = raw.map { |e| JSON.parse(e) rescue nil }.compact
      end

      # Gather top query stats
      stats = []
      begin
        results = connection.exec_query(<<~SQL)
          SELECT DIGEST_TEXT, COUNT_STAR AS calls,
            ROUND(SUM_TIMER_WAIT / 1000000000, 1) AS total_time_ms,
            ROUND(AVG_TIMER_WAIT / 1000000000, 1) AS avg_time_ms,
            SUM_ROWS_EXAMINED AS rows_examined, SUM_ROWS_SENT AS rows_sent,
            FIRST_SEEN, LAST_SEEN
          FROM performance_schema.events_statements_summary_by_digest
          WHERE SCHEMA_NAME = #{connection.quote(connection.current_database)}
            AND DIGEST_TEXT IS NOT NULL
          ORDER BY SUM_TIMER_WAIT DESC LIMIT 30
        SQL
        stats = results.rows.map { |r| { sql: r[0].to_s.truncate(200), calls: r[1], total_ms: r[2], avg_ms: r[3], rows_examined: r[4], rows_sent: r[5], first_seen: r[6], last_seen: r[7] } }
      rescue
        # performance_schema may not be available
      end

      slow_summary = slow_data.first(50).map { |q| "#{q['duration_ms']}ms @ #{q['timestamp']}: #{q['sql'].to_s.truncate(150)}" }.join("\n")
      stats_summary = stats.map { |q| "calls=#{q[:calls]} avg=#{q[:avg_ms]}ms total=#{q[:total_ms]}ms exam=#{q[:rows_examined]} sent=#{q[:rows_sent]}: #{q[:sql]}" }.join("\n")

      messages = [
        { role: "system", content: <<~PROMPT },
          You are a MySQL query anomaly detector. Analyze the following query data and identify:
          1. Queries with degrading performance (high avg time relative to complexity)
          2. N+1 query patterns (same template called many times in short windows)
          3. Full table scans (rows_examined >> rows_sent)
          4. Sudden new query patterns that may indicate code changes
          5. Queries creating excessive temp tables or sorts
          #{ai_domain_context}

          Respond with JSON: {"report": "markdown-formatted health report organized by severity. For each finding, explain the issue, affected query, and recommended fix."}
        PROMPT
        { role: "user", content: "Recent Slow Queries (last #{slow_data.size}):\n#{slow_summary.presence || 'None captured'}\n\nTop Queries by Total Time:\n#{stats_summary.presence || 'Not available'}" }
      ]

      result = AiClient.new.chat(messages: messages)
      render json: result
    rescue StandardError => e
      render json: { error: "Anomaly detection failed: #{e.message}" }, status: :unprocessable_entity
    end

    def root_cause
      return ai_not_configured unless mysql_genius_config.ai_enabled?
      connection = ActiveRecord::Base.connection

      # PROCESSLIST
      processlist = connection.exec_query("SHOW FULL PROCESSLIST")
      process_info = processlist.rows.map { |r| "ID=#{r[0]} User=#{r[1]} Host=#{r[2]} DB=#{r[3]} Command=#{r[4]} Time=#{r[5]}s State=#{r[6]} SQL=#{r[7].to_s.truncate(200)}" }.join("\n")

      # Key status variables
      status_rows = connection.exec_query("SHOW GLOBAL STATUS")
      status = {}
      status_rows.each { |r| status[(r["Variable_name"] || r["variable_name"]).to_s] = (r["Value"] || r["value"]).to_s }

      key_stats = %w[Threads_connected Threads_running Innodb_row_lock_waits Innodb_row_lock_current_waits
        Innodb_buffer_pool_reads Innodb_buffer_pool_read_requests Slow_queries Created_tmp_disk_tables
        Connections Aborted_connects].map { |k| "#{k}=#{status[k]}" }.join(", ")

      # InnoDB status (truncated)
      innodb_status = ""
      begin
        result = connection.exec_query("SHOW ENGINE INNODB STATUS")
        innodb_status = result.rows.first&.last.to_s.truncate(3000)
      rescue
      end

      # Recent slow queries
      slow_summary = ""
      if mysql_genius_config.redis_url
        redis = Redis.new(url: mysql_genius_config.redis_url)
        raw = redis.lrange(SlowQueryMonitor.redis_key, 0, 19)
        slows = raw.map { |e| JSON.parse(e) rescue nil }.compact
        slow_summary = slows.map { |q| "#{q['duration_ms']}ms: #{q['sql'].to_s.truncate(150)}" }.join("\n")
      end

      messages = [
        { role: "system", content: <<~PROMPT },
          You are a MySQL incident responder. The user is asking "why is the database slow right now?" Analyze the provided data and give a root cause diagnosis. Consider:
          - Lock contention (row locks, metadata locks, table locks)
          - Long-running queries blocking others
          - Connection exhaustion
          - Buffer pool thrashing (low hit rate)
          - Disk I/O saturation
          - Replication lag
          - Unusual query patterns
          #{ai_domain_context}

          Respond with JSON: {"diagnosis": "markdown-formatted root cause analysis. Start with a 1-2 sentence summary, then detailed findings. Include specific actionable steps to resolve the issue."}
        PROMPT
        { role: "user", content: "PROCESSLIST:\n#{process_info}\n\nKey Status:\n#{key_stats}\n\nInnoDB Status (excerpt):\n#{innodb_status.presence || 'Not available'}\n\nRecent Slow Queries:\n#{slow_summary.presence || 'None captured'}" }
      ]

      result = AiClient.new.chat(messages: messages)
      render json: result
    rescue StandardError => e
      render json: { error: "Root cause analysis failed: #{e.message}" }, status: :unprocessable_entity
    end

    def migration_risk
      return ai_not_configured unless mysql_genius_config.ai_enabled?
      migration_sql = params[:migration].to_s.strip
      return render json: { error: "Migration SQL or Ruby code is required." }, status: :unprocessable_entity if migration_sql.blank?

      connection = ActiveRecord::Base.connection

      # Try to identify tables mentioned in the migration
      table_names = migration_sql.scan(/(?:create_table|add_column|remove_column|add_index|remove_index|rename_column|change_column|alter\s+table)\s+[:\"]?(\w+)/i).flatten.uniq
      table_names += migration_sql.scan(/ALTER\s+TABLE\s+`?(\w+)`?/i).flatten

      table_info = table_names.uniq.map do |t|
        next unless connection.tables.include?(t)
        row_count = connection.exec_query("SELECT TABLE_ROWS FROM information_schema.tables WHERE table_schema = #{connection.quote(connection.current_database)} AND table_name = #{connection.quote(t)}").rows.first&.first
        indexes = connection.indexes(t).map { |idx| "#{idx.name} (#{idx.columns.join(', ')})" }
        "Table: #{t} (~#{row_count} rows, #{indexes.size} indexes)"
      end.compact.join("\n")

      # Current active queries on those tables
      active = ""
      begin
        results = connection.exec_query(<<~SQL)
          SELECT DIGEST_TEXT, COUNT_STAR AS calls, ROUND(AVG_TIMER_WAIT / 1000000000, 1) AS avg_ms
          FROM performance_schema.events_statements_summary_by_digest
          WHERE SCHEMA_NAME = #{connection.quote(connection.current_database)}
            AND DIGEST_TEXT IS NOT NULL
            AND COUNT_STAR > 10
          ORDER BY COUNT_STAR DESC LIMIT 20
        SQL
        matching = results.rows.select { |r| table_names.any? { |t| r[0].to_s.downcase.include?(t.downcase) } }
        active = matching.map { |r| "calls=#{r[1]} avg=#{r[2]}ms: #{r[0].to_s.truncate(200)}" }.join("\n")
      rescue
      end

      messages = [
        { role: "system", content: <<~PROMPT },
          You are a MySQL migration risk assessor. Given a Rails migration or DDL, evaluate:
          1. Will this lock the table? For how long given the row count?
          2. Is this safe to run during traffic, or does it need a maintenance window?
          3. Should pt-online-schema-change or gh-ost be used instead?
          4. Will it break or degrade any of the active queries against this table?
          5. Are there any data loss risks?
          6. What is the recommended deployment strategy?
          #{ai_domain_context}

          Respond with JSON: {"risk_level": "low|medium|high|critical", "assessment": "markdown-formatted risk assessment with specific recommendations and estimated lock duration"}
        PROMPT
        { role: "user", content: "Migration:\n#{migration_sql}\n\nAffected Tables:\n#{table_info.presence || 'Could not determine'}\n\nActive Queries on These Tables:\n#{active.presence || 'None found or performance_schema unavailable'}" }
      ]

      result = AiClient.new.chat(messages: messages)
      render json: result
    rescue StandardError => e
      render json: { error: "Migration risk assessment failed: #{e.message}" }, status: :unprocessable_entity
    end

    private

    def ai_not_configured
      render json: { error: "AI features are not configured." }, status: :not_found
    end

    def ai_domain_context
      ctx = mysql_genius_config.ai_system_context
      ctx.present? ? "\nDomain context:\n#{ctx}" : ""
    end

    def build_schema_for_query(sql)
      connection = ActiveRecord::Base.connection
      tables = SqlValidator.extract_table_references(sql, connection)
      tables.map do |t|
        cols = connection.columns(t).map { |c| "#{c.name} (#{c.type})" }
        "#{t}: #{cols.join(', ')}"
      end.join("\n")
    end

    def queryable_tables
      ActiveRecord::Base.connection.tables - mysql_genius_config.blocked_tables
    end

    def validate_sql(sql)
      SqlValidator.validate(sql, blocked_tables: mysql_genius_config.blocked_tables, connection: ActiveRecord::Base.connection)
    end

    def apply_timeout_hint(sql)
      if mariadb?
        timeout_seconds = mysql_genius_config.query_timeout_ms / 1000
        "SET STATEMENT max_statement_time=#{timeout_seconds} FOR #{sql}"
      else
        sql.sub(/\bSELECT\b/i, "SELECT /*+ MAX_EXECUTION_TIME(#{mysql_genius_config.query_timeout_ms}) */")
      end
    end

    def mariadb?
      @mariadb ||= ActiveRecord::Base.connection.select_value("SELECT VERSION()").to_s.include?("MariaDB")
    end

    def apply_row_limit(sql, limit)
      SqlValidator.apply_row_limit(sql, limit)
    end

    def timeout_error?(exception)
      msg = exception.message
      msg.include?("max_statement_time") || msg.include?("max_execution_time") || msg.include?("Query execution was interrupted")
    end

    def masked_column?(column_name)
      SqlValidator.masked_column?(column_name, mysql_genius_config.masked_column_patterns)
    end

    def sanitize_ai_sql(sql)
      sql.gsub(/```(?:sql)?\s*/i, "").gsub(/```/, "").strip
    end

    def audit(type, **attrs)
      logger = mysql_genius_config.audit_logger
      return unless logger

      prefix = "[#{Time.current.iso8601}] [mysql_genius]"
      case type
      when :query
        logger.info("#{prefix} rows=#{attrs[:row_count]} time=#{attrs[:execution_time_ms]}ms sql=#{attrs[:sql].squish}")
      when :rejection
        logger.warn("#{prefix} REJECTED reason=#{attrs[:reason]} sql=#{attrs[:sql].to_s.squish}")
      when :error
        logger.error("#{prefix} ERROR error=#{attrs[:error]} sql=#{attrs[:sql].to_s.squish}")
      end
    end
  end
end
