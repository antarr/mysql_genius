# frozen_string_literal: true

module MysqlGenius
  class QueriesController < BaseController
    include QueryExecution
    include DatabaseAnalysis
    include AiFeatures

    def index
      db_config = current_database_config
      @featured_tables = if db_config.featured_tables.any?
        db_config.featured_tables.sort
      else
        queryable_tables.sort
      end
      @all_tables = queryable_tables.sort
      @ai_enabled = mysql_genius_config.ai_enabled?
      @multi_db = multi_db?
      @current_database_key = current_database_key
      @available_databases = available_databases
    end

    def columns
      table = params[:table]
      if current_database_config.blocked_tables.include?(table)
        return render(json: { error: "Table '#{table}' is not available for querying." }, status: :forbidden)
      end

      unless connection.tables.include?(table)
        return render(json: { error: "Table '#{table}' does not exist." }, status: :not_found)
      end

      defaults = current_database_config.default_columns[table] || []
      cols = connection.columns(table).reject { |c| masked_column?(c.name) }.map do |c|
        { name: c.name, type: c.type.to_s, default: defaults.empty? || defaults.include?(c.name) }
      end
      render(json: cols)
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
      connection.tables - current_database_config.blocked_tables
    end
  end
end
