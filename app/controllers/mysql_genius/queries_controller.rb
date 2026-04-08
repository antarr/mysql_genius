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

    private

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
