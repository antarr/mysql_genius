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

      service = MysqlGenius::Core::Ai::Suggestion.new(rails_connection, ai_client, ai_config_for_core)
      result = service.call(prompt, queryable_tables)
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

      service = MysqlGenius::Core::Ai::Optimization.new(rails_connection, ai_client, ai_config_for_core)
      result = service.call(sql, explain_rows, queryable_tables)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Optimization failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def describe_query
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      sql = params[:sql].to_s.strip
      return render(json: { error: "SQL is required." }, status: :unprocessable_entity) if sql.blank?

      result = MysqlGenius::Core::Ai::DescribeQuery.new(ai_client, ai_config_for_core).call(sql)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Explanation failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def schema_review
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      result = MysqlGenius::Core::Ai::SchemaReview.new(ai_client, ai_config_for_core, rails_connection).call(params[:table].to_s.strip.presence)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Schema review failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def rewrite_query
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      sql = params[:sql].to_s.strip
      return render(json: { error: "SQL is required." }, status: :unprocessable_entity) if sql.blank?

      result = MysqlGenius::Core::Ai::RewriteQuery.new(ai_client, ai_config_for_core, rails_connection).call(sql)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Rewrite failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def index_advisor
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      sql = params[:sql].to_s.strip
      explain_rows = Array(params[:explain_rows]).map { |row| row.respond_to?(:values) ? row.values : Array(row) }
      return render(json: { error: "SQL and EXPLAIN output are required." }, status: :unprocessable_entity) if sql.blank? || explain_rows.blank?

      result = MysqlGenius::Core::Ai::IndexAdvisor.new(ai_client, ai_config_for_core, rails_connection).call(sql, explain_rows)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Index advisor failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def anomaly_detection
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      connection = ActiveRecord::Base.connection

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
      domain_ctx = mysql_genius_config.ai_system_context.present? ? "\nDomain context:\n#{mysql_genius_config.ai_system_context}" : ""

      messages = [
        { role: "system", content: <<~PROMPT },
          You are a MySQL query anomaly detector. Analyze the following query data and identify:
          1. Queries with degrading performance (high avg time relative to complexity)
          2. N+1 query patterns (same template called many times in short windows)
          3. Full table scans (rows_examined >> rows_sent)
          4. Sudden new query patterns that may indicate code changes
          5. Queries creating excessive temp tables or sorts
          #{domain_ctx}

          Respond with JSON: {"report": "markdown-formatted health report organized by severity. For each finding, explain the issue, affected query, and recommended fix."}
        PROMPT
        { role: "user", content: "Recent Slow Queries (last #{slow_data.size}):\n#{slow_summary.presence || "None captured"}\n\nTop Queries by Total Time:\n#{stats_summary.presence || "Not available"}" },
      ]

      result = ai_client.chat(messages: messages)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Anomaly detection failed: #{e.message}" }, status: :unprocessable_entity)
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

      domain_ctx = mysql_genius_config.ai_system_context.present? ? "\nDomain context:\n#{mysql_genius_config.ai_system_context}" : ""

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
          #{domain_ctx}

          Respond with JSON: {"diagnosis": "markdown-formatted root cause analysis. Start with a 1-2 sentence summary, then detailed findings. Include specific actionable steps to resolve the issue."}
        PROMPT
        { role: "user", content: "PROCESSLIST:\n#{process_info}\n\nKey Status:\n#{key_stats}\n\nInnoDB Status (excerpt):\n#{innodb_status.presence || "Not available"}\n\nRecent Slow Queries:\n#{slow_summary.presence || "None captured"}" },
      ]

      result = ai_client.chat(messages: messages)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Root cause analysis failed: #{e.message}" }, status: :unprocessable_entity)
    end

    def migration_risk
      return ai_not_configured unless mysql_genius_config.ai_enabled?

      migration_sql = params[:migration].to_s.strip
      return render(json: { error: "Migration SQL or Ruby code is required." }, status: :unprocessable_entity) if migration_sql.blank?

      result = MysqlGenius::Core::Ai::MigrationRisk.new(ai_client, ai_config_for_core, rails_connection).call(migration_sql)
      render(json: result)
    rescue StandardError => e
      render(json: { error: "Migration risk assessment failed: #{e.message}" }, status: :unprocessable_entity)
    end

    private

    RAILS_DOMAIN_CONTEXT = <<~CTX
      This is a Ruby on Rails application. Do NOT recommend adding foreign key constraints (FOREIGN KEY / REFERENCES); Rails handles referential integrity at the application layer. DO recommend indexes on foreign key columns for join performance.
    CTX

    def ai_client
      MysqlGenius::Core::Ai::Client.new(ai_config_for_core)
    end

    def ai_config_for_core
      cfg = mysql_genius_config
      MysqlGenius::Core::Ai::Config.new(
        client: cfg.ai_client,
        endpoint: cfg.ai_endpoint,
        api_key: cfg.ai_api_key,
        model: cfg.ai_model,
        auth_style: cfg.ai_auth_style,
        system_context: cfg.ai_system_context,
        domain_context: RAILS_DOMAIN_CONTEXT,
      )
    end

    def ai_not_configured
      render(json: { error: "AI features are not configured." }, status: :not_found)
    end
  end
end
