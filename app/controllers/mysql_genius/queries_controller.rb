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

    def query_history
      digest = params[:digest].to_s
      db = begin
        ActiveRecord::Base.connection.current_database
      rescue
        nil
      end

      current_query = fetch_query_history_current(digest, db)
      history = fetch_query_history_series(digest)

      render(json: { query: current_query, history: history })
    rescue StandardError => e
      render(json: { error: e.message }, status: :unprocessable_entity)
    end

    def slow_queries
      unless mysql_genius_config.redis_url.present?
        return render(json: [], status: :ok)
      end

      require "redis"
      redis = Redis.new(url: mysql_genius_config.redis_url)
      key = SlowQueryMonitor.redis_key
      raw = redis.lrange(key, 0, 199)
      queries = raw.map do |entry|
        JSON.parse(entry)
      rescue JSON::ParserError
        nil
      end.compact
      render(json: queries)
    rescue StandardError => e
      render(json: { error: "Slow query error: #{e.message}" }, status: :unprocessable_entity)
    end

    private

    def queryable_tables
      ActiveRecord::Base.connection.tables - mysql_genius_config.blocked_tables
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
      result = ActiveRecord::Base.connection.exec_query(sql)
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
      result = ActiveRecord::Base.connection.exec_query(sql)
      result.rows.empty? ? nil : result.to_a.first["DIGEST_TEXT"]
    end
  end
end
