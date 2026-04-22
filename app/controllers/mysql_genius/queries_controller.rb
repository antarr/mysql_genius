# frozen_string_literal: true

module MysqlGenius
  class QueriesController < BaseController
    include QueryExecution
    include DatabaseAnalysis
    include AiFeatures
    include SharedViewHelpers

    def index
      @featured_tables = if mysql_genius_config.featured_tables.any?
        mysql_genius_config.featured_tables.sort
      else
        queryable_tables.sort
      end
      @all_tables = queryable_tables.sort
      @ai_enabled = mysql_genius_config.ai_enabled?
      @framework_version_major = Rails::VERSION::MAJOR
      @framework_version_minor = Rails::VERSION::MINOR
      render("mysql_genius/queries/dashboard")
    end

    def columns
      result = MysqlGenius::Core::Analysis::Columns.new(
        rails_connection,
        blocked_tables: mysql_genius_config.blocked_tables,
        masked_column_patterns: mysql_genius_config.masked_column_patterns,
        default_columns: mysql_genius_config.default_columns,
      ).call(table: params[:table])

      case result.status
      when :ok        then render(json: result.columns)
      when :blocked   then render(json: { error: result.error_message }, status: :forbidden)
      when :not_found then render(json: { error: result.error_message }, status: :not_found)
      end
    end

    def query_detail
      @digest = params[:digest].to_s
      render("mysql_genius/queries/query_detail")
    end

    # Rendered when no MySQL connection is discovered from config/database.yml.
    # Shows an example database.yml entry so first-time users have an actionable
    # next step.
    def setup
      @rails_env = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env : "development"
      render("mysql_genius/queries/setup")
    end

    def query_history
      digest = params[:digest].to_s
      db = begin
        active_record_connection.current_database
      rescue
        nil
      end

      current_query = fetch_query_history_current(digest, db)
      history = fetch_query_history_series(digest)

      render(json: { query: current_query, history: history })
    rescue StandardError => e
      render(json: { error: e.message }, status: :unprocessable_entity)
    end

    # Returns slow queries for the current database, merging two sources:
    #
    #   - performance_schema.events_statements_history_long (always attempted;
    #     zero-config, no dependency). Gives broad visibility including queries
    #     from other clients of this MySQL server, but no Rails-side context.
    #
    #   - Redis-captured slow queries (only when `c.redis_url` is configured).
    #     Adds Rails-side metadata (payload :name) that performance_schema
    #     can't provide.
    #
    # The frontend consumes a bare JSON array sorted by duration desc, capped
    # at 200 entries. Each item has a `source` field ("performance_schema" or
    # "rails") indicating its origin.
    def slow_queries
      combined = fetch_perf_schema_slow_queries + fetch_rails_side_slow_queries
      sorted = combined.sort_by { |q| -(q[:duration_ms] || q["duration_ms"]).to_f }.first(200)
      render(json: sorted)
    rescue StandardError => e
      render(json: { error: "Slow query error: #{e.message}" }, status: :unprocessable_entity)
    end

    private

    def queryable_tables
      active_record_connection.tables - mysql_genius_config.blocked_tables
    end

    def fetch_perf_schema_slow_queries
      result = MysqlGenius::Core::Analysis::SlowQueries.new(
        rails_connection,
        threshold_ms: mysql_genius_config.slow_query_threshold_ms,
      ).call
      result.queries
    rescue StandardError
      # Defensive: SlowQueries#call already funnels errors into an unavailable
      # Result, but guard in case something unexpected escapes.
      []
    end

    def fetch_rails_side_slow_queries
      return [] unless mysql_genius_config.redis_url.present?

      require "redis"
      require "mysql_genius/slow_query_monitor"
      redis = Redis.new(url: mysql_genius_config.redis_url)
      raw = redis.lrange(MysqlGenius::SlowQueryMonitor.redis_key, 0, 199)
      raw.filter_map do |entry|
        parsed = JSON.parse(entry)
        {
          sql: parsed["sql"],
          digest_text: nil,
          digest: nil,
          duration_ms: parsed["duration_ms"].to_f,
          timestamp: parsed["timestamp"],
          name: parsed["name"],
          source: "rails",
        }
      rescue JSON::ParserError
        nil
      end
    rescue StandardError
      # Redis unreachable — degrade silently so the perf_schema source still renders.
      []
    end

    def fetch_query_history_current(digest, db)
      sql = <<~SQL.squish
        SELECT DIGEST_TEXT, COUNT_STAR AS calls,
               ROUND(SUM_TIMER_WAIT / 1000000000.0, 2) AS total_time_ms,
               ROUND(AVG_TIMER_WAIT / 1000000000.0, 2) AS avg_time_ms,
               ROUND(MAX_TIMER_WAIT / 1000000000.0, 2) AS max_time_ms,
               SUM_ROWS_EXAMINED AS rows_examined,
               SUM_ROWS_SENT AS rows_sent,
               FIRST_SEEN, LAST_SEEN
        FROM performance_schema.events_statements_summary_by_digest
        WHERE DIGEST = '#{digest.gsub("'", "''")}'
        #{"AND SCHEMA_NAME = '#{db.to_s.gsub("'", "''")}'" if db}
        LIMIT 1
      SQL
      result = active_record_connection.exec_query(sql)
      return if result.rows.empty?

      row = result.to_a.first
      {
        sql: row["DIGEST_TEXT"],
        calls: row["calls"],
        total_time_ms: row["total_time_ms"].to_f,
        avg_time_ms: row["avg_time_ms"].to_f,
        max_time_ms: row["max_time_ms"].to_f,
        rows_examined: row["rows_examined"],
        rows_sent: row["rows_sent"],
        first_seen: row["FIRST_SEEN"].to_s,
        last_seen: row["LAST_SEEN"].to_s,
      }
    end

    def fetch_query_history_series(digest)
      return [] unless MysqlGenius.stats_history

      digest_text = lookup_digest_text(digest)
      return [] unless digest_text

      MysqlGenius.stats_history.series_for(digest_text)
    end

    def lookup_digest_text(digest)
      sql = <<~SQL.squish
        SELECT DIGEST_TEXT FROM performance_schema.events_statements_summary_by_digest
        WHERE DIGEST = '#{digest.gsub("'", "''")}' LIMIT 1
      SQL
      result = active_record_connection.exec_query(sql)
      result.rows.empty? ? nil : result.to_a.first["DIGEST_TEXT"]
    end
  end
end
