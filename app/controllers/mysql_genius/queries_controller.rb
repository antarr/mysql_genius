module MysqlGenius
  class QueriesController < BaseController
    FORBIDDEN_KEYWORDS = %w[INSERT UPDATE DELETE DROP ALTER CREATE TRUNCATE GRANT REVOKE].freeze

    def index
      @featured_tables = if config.featured_tables.any?
                           config.featured_tables.sort
                         else
                           queryable_tables.sort
                         end
      @all_tables = queryable_tables.sort
      @ai_enabled = config.ai_enabled?
    end

    def slow_queries
      unless config.redis_url.present?
        return render json: { error: "Slow query monitoring is not configured." }, status: :not_found
      end

      redis = Redis.new(url: config.redis_url)
      key = SlowQueryMonitor.redis_key
      raw = redis.lrange(key, 0, 199)
      queries = raw.map { |entry| JSON.parse(entry) rescue nil }.compact
      render json: queries
    rescue => e
      render json: [], status: :ok
    end

    def columns
      table = params[:table]
      if config.blocked_tables.include?(table)
        return render json: { error: "Table '#{table}' is not available for querying." }, status: :forbidden
      end

      unless ActiveRecord::Base.connection.tables.include?(table)
        return render json: { error: "Table '#{table}' does not exist." }, status: :not_found
      end

      defaults = config.default_columns[table] || []
      cols = ActiveRecord::Base.connection.columns(table).reject { |c| masked_column?(c.name) }.map do |c|
        { name: c.name, type: c.type.to_s, default: defaults.empty? || defaults.include?(c.name) }
      end
      render json: cols
    end

    def execute
      sql = params[:sql].to_s.strip
      row_limit = if params[:row_limit].present?
                    [[params[:row_limit].to_i, 1].max, config.max_row_limit].min
                  else
                    config.default_row_limit
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
          render json: { error: "Query exceeded the #{config.query_timeout_ms / 1000} second timeout limit.", timeout: true }, status: :unprocessable_entity
        else
          audit(:error, sql: sql, error: e.message)
          render json: { error: "Query error: #{e.message.split(':').last.strip}" }, status: :unprocessable_entity
        end
      end
    end

    def explain
      sql = params[:sql].to_s.strip

      error = validate_sql(sql)
      return render json: { error: error }, status: :unprocessable_entity if error

      explain_sql = "EXPLAIN #{sql.gsub(/;\s*\z/, '')}"
      results = ActiveRecord::Base.connection.exec_query(explain_sql)

      render json: { columns: results.columns, rows: results.rows }
    rescue ActiveRecord::StatementInvalid => e
      render json: { error: "Explain error: #{e.message.split(':').last.strip}" }, status: :unprocessable_entity
    end

    def suggest
      unless config.ai_enabled?
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
      unless config.ai_enabled?
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

    private

    def queryable_tables
      ActiveRecord::Base.connection.tables - config.blocked_tables
    end

    def validate_sql(sql)
      return "Please enter a query." if sql.blank?

      normalized = sql.gsub(/--.*$/, "").gsub(%r{/\*.*?\*/}m, "").strip

      unless normalized.match?(/\ASELECT\b/i) || normalized.match?(/\AWITH\b/i)
        return "Only SELECT queries are allowed."
      end

      return "Access to system schemas is not allowed." if normalized.match?(/\b(information_schema|mysql|performance_schema|sys)\b/i)

      FORBIDDEN_KEYWORDS.each do |keyword|
        return "#{keyword} statements are not allowed." if normalized.match?(/\b#{keyword}\b/i)
      end

      tables_in_query = extract_table_references(normalized)
      blocked = tables_in_query & config.blocked_tables
      if blocked.any?
        return "Access denied for table(s): #{blocked.join(', ')}."
      end

      nil
    end

    def extract_table_references(sql)
      tables = []
      sql.scan(/\bFROM\s+((?:`?\w+`?(?:\s*,\s*`?\w+`?)*)+)/i) { |m| m[0].scan(/`?(\w+)`?/) { |t| tables << t[0] } }
      sql.scan(/\bJOIN\s+`?(\w+)`?/i) { |m| tables << m[0] }
      sql.scan(/\b(?:INTO|UPDATE)\s+`?(\w+)`?/i) { |m| tables << m[0] }
      tables.uniq.map(&:downcase) & ActiveRecord::Base.connection.tables
    end

    def apply_timeout_hint(sql)
      if mariadb?
        timeout_seconds = config.query_timeout_ms / 1000
        "SET STATEMENT max_statement_time=#{timeout_seconds} FOR #{sql}"
      else
        sql.sub(/\bSELECT\b/i, "SELECT /*+ MAX_EXECUTION_TIME(#{config.query_timeout_ms}) */")
      end
    end

    def mariadb?
      @mariadb ||= ActiveRecord::Base.connection.select_value("SELECT VERSION()").to_s.include?("MariaDB")
    end

    def apply_row_limit(sql, limit)
      if sql.match?(/\bLIMIT\s+\d+\s*,\s*\d+/i)
        sql.gsub(/\bLIMIT\s+(\d+)\s*,\s*(\d+)/i) do
          "LIMIT #{::Regexp.last_match(1).to_i}, #{[::Regexp.last_match(2).to_i, limit].min}"
        end
      elsif sql.match?(/\bLIMIT\s+\d+/i)
        sql.gsub(/\bLIMIT\s+(\d+)/i) { "LIMIT #{[::Regexp.last_match(1).to_i, limit].min}" }
      else
        "#{sql.gsub(/;\s*\z/, '')} LIMIT #{limit}"
      end
    end

    def timeout_error?(exception)
      msg = exception.message
      msg.include?("max_statement_time") || msg.include?("max_execution_time") || msg.include?("Query execution was interrupted")
    end

    def masked_column?(column_name)
      config.masked_column_patterns.any? { |pattern| column_name.downcase.include?(pattern) }
    end

    def sanitize_ai_sql(sql)
      sql.gsub(/```(?:sql)?\s*/i, "").gsub(/```/, "").strip
    end

    def audit(type, **attrs)
      logger = config.audit_logger
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
