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
      table = params[:table]
      if mysql_genius_config.blocked_tables.include?(table)
        return render(json: { error: "Table '#{table}' is not available for querying." }, status: :forbidden)
      end

      unless ActiveRecord::Base.connection.tables.include?(table)
        return render(json: { error: "Table '#{table}' does not exist." }, status: :not_found)
      end

      defaults = mysql_genius_config.default_columns[table] || []
      cols = ActiveRecord::Base.connection.columns(table).reject { |c| masked_column?(c.name) }.map do |c|
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
      ActiveRecord::Base.connection.tables - mysql_genius_config.blocked_tables
    end

    # Delegates to Core::SqlValidator's 2-arg class method. A bare
    # `masked_column?(name)` call survives on line 30 because this helper
    # reintroduces the 1-arg instance method the controller's `columns`
    # action depends on. Without this helper, `columns` raises NoMethodError
    # at runtime (Phase 1b regression — Core::SqlValidator.masked_column?
    # became a 2-arg class method but the call site wasn't updated).
    def masked_column?(name)
      MysqlGenius::Core::SqlValidator.masked_column?(name, mysql_genius_config.masked_column_patterns)
    end
  end
end
