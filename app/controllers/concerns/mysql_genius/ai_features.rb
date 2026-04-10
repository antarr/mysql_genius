# frozen_string_literal: true

module MysqlGenius
  module AiFeatures
    extend ActiveSupport::Concern

    def suggest
      unless mysql_genius_config.ai_enabled?
        return render(json: { error: "AI features are not configured." }, status: :not_found)
      end

      prompt = params[:prompt].to_s.strip
      return render(json: { error: "Please describe what you want to query." }, status: :unprocessable_entity) if prompt.blank?

      result = AiSuggestionService.new.call(prompt, queryable_tables, connection: connection)
      sql = sanitize_ai_sql(result["sql"].to_s)
      render(json: { sql: sql, explanation: result["explanation"] })
    rescue StandardError => e
      render(json: { error: "AI suggestion failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def optimize
      unless mysql_genius_config.ai_enabled?
        return render(json: { error: "AI features are not configured." }, status: :not_found)
      end

      sql = params[:sql].to_s.strip
      explain_rows = Array(params[:explain_rows]).map { |row| row.respond_to?(:values) ? row.values : Array(row) }

      if sql.blank? || explain_rows.blank?
        return render(json: { error: "SQL and EXPLAIN output are required." }, status: :unprocessable_entity)
      end

      result = AiOptimizationService.new.call(sql, explain_rows, queryable_tables, connection: connection)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Optimization failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def describe_query
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      sql = params[:sql].to_s.strip
      return render(json: { error: "SQL is required." }, status: :unprocessable_entity) if sql.blank?

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
        { role: "user", content: sql },
      ]

      result = AiClient.new.chat(messages: messages)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Explanation failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def schema_review
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      table = params[:table].to_s.strip

      tables_to_review = table.present? ? [table] : queryable_tables.first(20)
      schema_desc = tables_to_review.map do |t|
        next unless connection.tables.include?(t)

        cols = connection.columns(t).map { |c| "#{c.name} #{c.sql_type}#{" NOT NULL" unless c.null}#{" DEFAULT #{c.default}" if c.default}" }
        pk = connection.primary_key(t)
        indexes = connection.indexes(t).map { |idx| "#{"UNIQUE " if idx.unique}INDEX #{idx.name} (#{idx.columns.join(", ")})" }
        row_count = connection.exec_query("SELECT TABLE_ROWS FROM information_schema.tables WHERE table_schema = #{connection.quote(connection.current_database)} AND table_name = #{connection.quote(t)}").rows.first&.first
        desc = "Table: #{t} (~#{row_count} rows)\n"
        desc += "Primary Key: #{pk || "NONE"}\n"
        desc += "Columns: #{cols.join(", ")}\n"
        desc += "Indexes: #{indexes.any? ? indexes.join(", ") : "NONE"}"
        desc
      end.compact.join("\n\n")

      messages = [
        { role: "system", content: <<~PROMPT },
          You are a MySQL schema reviewer for a Ruby on Rails application. Analyze the following schema and identify anti-patterns and improvement opportunities. Look for:
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
        { role: "user", content: schema_desc },
      ]

      result = AiClient.new.chat(messages: messages)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Schema review failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def rewrite_query
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      sql = params[:sql].to_s.strip
      return render(json: { error: "SQL is required." }, status: :unprocessable_entity) if sql.blank?

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
        { role: "user", content: sql },
      ]

      result = AiClient.new.chat(messages: messages)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Rewrite failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def index_advisor
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      sql = params[:sql].to_s.strip
      explain_rows = Array(params[:explain_rows]).map { |row| row.respond_to?(:values) ? row.values : Array(row) }
      return render(json: { error: "SQL and EXPLAIN output are required." }, status: :unprocessable_entity) if sql.blank? || explain_rows.blank?

      tables_in_query = SqlValidator.extract_table_references(sql, connection)

      index_detail = tables_in_query.map do |t|
        indexes = connection.indexes(t).map { |idx| "#{"UNIQUE " if idx.unique}INDEX #{idx.name} (#{idx.columns.join(", ")})" }
        stats = connection.exec_query("SELECT INDEX_NAME, COLUMN_NAME, CARDINALITY, SEQ_IN_INDEX FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = #{connection.quote(connection.current_database)} AND TABLE_NAME = #{connection.quote(t)} ORDER BY INDEX_NAME, SEQ_IN_INDEX")
        cardinality = stats.rows.map { |r| "#{r[0]}.#{r[1]}: cardinality=#{r[2]}" }.join(", ")
        row_count = connection.exec_query("SELECT TABLE_ROWS FROM information_schema.tables WHERE table_schema = #{connection.quote(connection.current_database)} AND table_name = #{connection.quote(t)}").rows.first&.first
        "Table: #{t} (~#{row_count} rows)\nIndexes: #{indexes.any? ? indexes.join("; ") : "NONE"}\nCardinality: #{cardinality}"
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
        { role: "user", content: "Query:\n#{sql}\n\nEXPLAIN:\n#{explain_rows.map { |r| r.join(" | ") }.join("\n")}\n\nCurrent Indexes:\n#{index_detail}" },
      ]

      result = AiClient.new.chat(messages: messages)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Index advisor failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def anomaly_detection
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      # Gather recent slow queries
      slow_data = []
      if mysql_genius_config.redis_url
        redis = Redis.new(url: mysql_genius_config.redis_url)
        raw = redis.lrange(SlowQueryMonitor.redis_key, 0, 99)
        slow_data = raw.map do |e|
          JSON.parse(e)
        rescue
          nil
        end.compact
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

      slow_summary = slow_data.first(50).map { |q| "#{q["duration_ms"]}ms @ #{q["timestamp"]}: #{q["sql"].to_s.truncate(150)}" }.join("\n")
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
        { role: "user", content: "Recent Slow Queries (last #{slow_data.size}):\n#{slow_summary.presence || "None captured"}\n\nTop Queries by Total Time:\n#{stats_summary.presence || "Not available"}" },
      ]

      result = AiClient.new.chat(messages: messages)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Anomaly detection failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def root_cause
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      # PROCESSLIST
      processlist = connection.exec_query("SHOW FULL PROCESSLIST")
      process_info = processlist.rows.map { |r| "ID=#{r[0]} User=#{r[1]} Host=#{r[2]} DB=#{r[3]} Command=#{r[4]} Time=#{r[5]}s State=#{r[6]} SQL=#{r[7].to_s.truncate(200)}" }.join("\n")

      # Key status variables
      status_rows = connection.exec_query("SHOW GLOBAL STATUS")
      status = {}
      status_rows.each { |r| status[(r["Variable_name"] || r["variable_name"]).to_s] = (r["Value"] || r["value"]).to_s }

      key_stats = [
        "Threads_connected",
        "Threads_running",
        "Innodb_row_lock_waits",
        "Innodb_row_lock_current_waits",
        "Innodb_buffer_pool_reads",
        "Innodb_buffer_pool_read_requests",
        "Slow_queries",
        "Created_tmp_disk_tables",
        "Connections",
        "Aborted_connects",
      ].map { |k| "#{k}=#{status[k]}" }.join(", ")

      # InnoDB status (truncated)
      innodb_status = ""
      begin
        result = connection.exec_query("SHOW ENGINE INNODB STATUS")
        innodb_status = result.rows.first&.last.to_s.truncate(3000)
      rescue ActiveRecord::StatementInvalid
        # InnoDB status may be unavailable depending on MySQL user privileges
      end

      # Recent slow queries
      slow_summary = ""
      if mysql_genius_config.redis_url
        redis = Redis.new(url: mysql_genius_config.redis_url)
        raw = redis.lrange(SlowQueryMonitor.redis_key, 0, 19)
        slows = raw.map do |e|
          JSON.parse(e)
        rescue
          nil
        end.compact
        slow_summary = slows.map { |q| "#{q["duration_ms"]}ms: #{q["sql"].to_s.truncate(150)}" }.join("\n")
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
        { role: "user", content: "PROCESSLIST:\n#{process_info}\n\nKey Status:\n#{key_stats}\n\nInnoDB Status (excerpt):\n#{innodb_status.presence || "Not available"}\n\nRecent Slow Queries:\n#{slow_summary.presence || "None captured"}" },
      ]

      result = AiClient.new.chat(messages: messages)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Root cause analysis failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def migration_risk
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      migration_sql = params[:migration].to_s.strip
      return render(json: { error: "Migration SQL or Ruby code is required." }, status: :unprocessable_entity) if migration_sql.blank?

      # Try to identify tables mentioned in the migration
      table_names = migration_sql.scan(/(?:create_table|add_column|remove_column|add_index|remove_index|rename_column|change_column|alter\s+table)\s+[:\"]?(\w+)/i).flatten.uniq
      table_names += migration_sql.scan(/ALTER\s+TABLE\s+`?(\w+)`?/i).flatten

      table_info = table_names.uniq.map do |t|
        next unless connection.tables.include?(t)

        row_count = connection.exec_query("SELECT TABLE_ROWS FROM information_schema.tables WHERE table_schema = #{connection.quote(connection.current_database)} AND table_name = #{connection.quote(t)}").rows.first&.first
        indexes = connection.indexes(t).map { |idx| "#{idx.name} (#{idx.columns.join(", ")})" }
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
      rescue ActiveRecord::StatementInvalid
        # performance_schema may be unavailable
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
        { role: "user", content: "Migration:\n#{migration_sql}\n\nAffected Tables:\n#{table_info.presence || "Could not determine"}\n\nActive Queries on These Tables:\n#{active.presence || "None found or performance_schema unavailable"}" },
      ]

      result = AiClient.new.chat(messages: messages)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Migration risk assessment failed: #{e.message}" }, status: :unprocessable_entity)
    end

    private

    def ai_not_configured
      render(json: { error: "AI features are not configured." }, status: :not_found)
    end

    def ai_domain_context
      parts = []
      parts << "This is a Ruby on Rails application. Do NOT recommend adding foreign key constraints (FOREIGN KEY / REFERENCES); Rails handles referential integrity at the application layer. DO recommend indexes on foreign key columns for join performance."
      ctx = mysql_genius_config.ai_system_context
      parts << "Domain context:\n#{ctx}" if ctx.present?
      "\n" + parts.join("\n")
    end

    def build_schema_for_query(sql)
      tables = SqlValidator.extract_table_references(sql, connection)
      tables.map do |t|
        cols = connection.columns(t).map { |c| "#{c.name} (#{c.type})" }
        "#{t}: #{cols.join(", ")}"
      end.join("\n")
    end
  end
end
