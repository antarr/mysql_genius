# frozen_string_literal: true

module MysqlGenius
  module QueryExecution
    extend ActiveSupport::Concern

    def execute
      sql = params[:sql].to_s.strip
      row_limit = if params[:row_limit].present?
        params[:row_limit].to_i.clamp(1, mysql_genius_config.max_row_limit)
      else
        mysql_genius_config.default_row_limit
      end

      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      runner_config = MysqlGenius::Core::QueryRunner::Config.new(
        blocked_tables: mysql_genius_config.blocked_tables,
        masked_column_patterns: mysql_genius_config.masked_column_patterns,
        query_timeout_ms: mysql_genius_config.query_timeout_ms,
      )
      runner = MysqlGenius::Core::QueryRunner.new(connection, runner_config)

      begin
        result = runner.run(sql, row_limit: row_limit)
      rescue MysqlGenius::Core::QueryRunner::Rejected => e
        audit(:rejection, sql: sql, reason: e.message)
        return render(json: { error: e.message }, status: :unprocessable_entity)
      rescue MysqlGenius::Core::QueryRunner::Timeout
        audit(:error, sql: sql, error: "Query timeout")
        return render(json: { error: "Query exceeded the #{mysql_genius_config.query_timeout_ms / 1000} second timeout limit.", timeout: true }, status: :unprocessable_entity)
      rescue ActiveRecord::StatementInvalid => e
        audit(:error, sql: sql, error: e.message)
        return render(json: { error: "Query error: #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
      end

      audit(:query, sql: sql, execution_time_ms: result.execution_time_ms, row_count: result.row_count)

      render(json: {
        columns: result.columns,
        rows: result.rows,
        row_count: result.row_count,
        execution_time_ms: result.execution_time_ms,
        truncated: result.truncated,
      })
    end

    def explain
      sql = params[:sql].to_s.strip
      skip_validation = params[:from_slow_query] == "true"

      unless skip_validation
        error = validate_sql(sql)
        return render(json: { error: error }, status: :unprocessable_entity) if error
      end

      # Reject truncated SQL (captured slow queries are capped at 2000 chars)
      unless sql.match?(/\)\s*$/) || sql.match?(/\w\s*$/) || sql.match?(/['"`]\s*$/) || sql.match?(/\d\s*$/)
        return render(json: { error: "This query appears to be truncated and cannot be explained." }, status: :unprocessable_entity)
      end

      explain_sql = "EXPLAIN #{sql.gsub(/;\s*\z/, "")}"
      results = ActiveRecord::Base.connection.exec_query(explain_sql)

      render(json: { columns: results.columns, rows: results.rows })
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Explain error: #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end

    private

    def validate_sql(sql)
      MysqlGenius::Core::SqlValidator.validate(sql, blocked_tables: mysql_genius_config.blocked_tables, connection: ActiveRecord::Base.connection)
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
      MysqlGenius::Core::SqlValidator.apply_row_limit(sql, limit)
    end

    def timeout_error?(exception)
      msg = exception.message
      msg.include?("max_statement_time") || msg.include?("max_execution_time") || msg.include?("Query execution was interrupted")
    end

    def masked_column?(column_name)
      MysqlGenius::Core::SqlValidator.masked_column?(column_name, mysql_genius_config.masked_column_patterns)
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
