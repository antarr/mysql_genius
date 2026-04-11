# frozen_string_literal: true

module MysqlGenius
  class QueriesController < BaseController
    include QueryExecution
    include DatabaseAnalysis
    include AiFeatures

    def index
      @featured_tables = if mysql_genius_config.featured_tables.any?
        mysql_genius_config.featured_tables.sort
      else
        queryable_tables.sort
      end
      @all_tables = queryable_tables.sort
      @ai_enabled = mysql_genius_config.ai_enabled?
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

    def rails_connection
      MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
    end
  end
end
