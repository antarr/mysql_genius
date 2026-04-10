# frozen_string_literal: true

module MysqlGenius
  module QueryExecution
    extend ActiveSupport::Concern

    def execute
      sql = params[:sql].to_s.strip
      db_config = current_database_config
      row_limit = if params[:row_limit].present?
        params[:row_limit].to_i.clamp(1, db_config.max_row_limit)
      else
        db_config.default_row_limit
      end

      error = validate_sql(sql)
      if error
        audit(:rejection, sql: sql, reason: error)
        return render(json: { error: error }, status: :unprocessable_entity)
      end

      limited_sql = apply_row_limit(sql, row_limit)
      timed_sql = apply_timeout_hint(limited_sql)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        results = connection.exec_query(timed_sql)
        execution_time_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)

        columns = results.columns
        rows = results.rows.map do |row|
          row.each_with_index.map do |value, i|
            masked_column?(columns[i]) ? "[REDACTED]" : value
          end
        end

        truncated = rows.length >= row_limit

        audit(:query, sql: sql, execution_time_ms: execution_time_ms, row_count: rows.length)

        render(json: {
          columns: columns,
          rows: rows,
          row_count: rows.length,
          execution_time_ms: execution_time_ms,
          truncated: truncated,
        })
      rescue ActiveRecord::StatementInvalid => e
        if timeout_error?(e)
          audit(:error, sql: sql, error: "Query timeout")
          render(json: { error: "Query exceeded the #{db_config.query_timeout_ms / 1000} second timeout limit.", timeout: true }, status: :unprocessable_entity)
        else
          audit(:error, sql: sql, error: e.message)
          render(json: { error: "Query error: #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
        end
      end
    end

    def explain
      sql = params[:sql].to_s.strip
      skip_validation = params[:from_slow_query] == "true"

      unless skip_validation
        error = validate_sql(sql)
        return render(json: { error: error }, status: :unprocessable_entity) if error
      end

      unless sql.match?(/\)\s*$/) || sql.match?(/\w\s*$/) || sql.match?(/['"`]\s*$/) || sql.match?(/\d\s*$/)
        return render(json: { error: "This query appears to be truncated and cannot be explained." }, status: :unprocessable_entity)
      end

      explain_sql = "EXPLAIN #{sql.gsub(/;\s*\z/, "")}"
      results = connection.exec_query(explain_sql)

      render(json: { columns: results.columns, rows: results.rows })
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Explain error: #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end

    private

    def validate_sql(sql)
      SqlValidator.validate(sql, blocked_tables: current_database_config.blocked_tables, connection: connection)
    end

    def apply_timeout_hint(sql)
      if mariadb?
        timeout_seconds = current_database_config.query_timeout_ms / 1000
        "SET STATEMENT max_statement_time=#{timeout_seconds} FOR #{sql}"
      else
        sql.sub(/\bSELECT\b/i, "SELECT /*+ MAX_EXECUTION_TIME(#{current_database_config.query_timeout_ms}) */")
      end
    end

    def mariadb?
      @mariadb ||= connection.select_value("SELECT VERSION()").to_s.include?("MariaDB")
    end

    def apply_row_limit(sql, limit)
      SqlValidator.apply_row_limit(sql, limit)
    end

    def timeout_error?(exception)
      msg = exception.message
      msg.include?("max_statement_time") || msg.include?("max_execution_time") || msg.include?("Query execution was interrupted")
    end

    def masked_column?(column_name)
      SqlValidator.masked_column?(column_name, current_database_config.masked_column_patterns)
    end

    def sanitize_ai_sql(sql)
      sql.gsub(/```(?:sql)?\s*/i, "").gsub("```", "").strip
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
