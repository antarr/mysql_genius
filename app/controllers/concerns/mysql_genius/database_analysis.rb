# frozen_string_literal: true

module MysqlGenius
  module DatabaseAnalysis
    extend ActiveSupport::Concern

    def duplicate_indexes
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      duplicates = MysqlGenius::Core::Analysis::DuplicateIndexes
        .new(connection, blocked_tables: mysql_genius_config.blocked_tables)
        .call
      render(json: duplicates)
    end

    def table_sizes
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      tables = MysqlGenius::Core::Analysis::TableSizes.new(connection).call
      render(json: tables)
    end

    def query_stats
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      sort = params[:sort].to_s
      limit = params.fetch(:limit, MysqlGenius::Core::Analysis::QueryStats::MAX_LIMIT).to_i
      queries = MysqlGenius::Core::Analysis::QueryStats.new(connection).call(sort: sort, limit: limit)
      render(json: queries)
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Query statistics require performance_schema to be enabled. #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end

    def unused_indexes
      connection = ActiveRecord::Base.connection
      db_name = connection.current_database

      results = connection.exec_query(<<~SQL)
        SELECT
          s.OBJECT_SCHEMA AS table_schema,
          s.OBJECT_NAME AS table_name,
          s.INDEX_NAME AS index_name,
          s.COUNT_READ AS `reads`,
          s.COUNT_WRITE AS `writes`,
          t.TABLE_ROWS AS table_rows
        FROM performance_schema.table_io_waits_summary_by_index_usage s
        JOIN information_schema.tables t
          ON t.TABLE_SCHEMA = s.OBJECT_SCHEMA AND t.TABLE_NAME = s.OBJECT_NAME
        WHERE s.OBJECT_SCHEMA = #{connection.quote(db_name)}
          AND s.INDEX_NAME IS NOT NULL
          AND s.INDEX_NAME != 'PRIMARY'
          AND s.COUNT_READ = 0
          AND t.TABLE_ROWS > 0
        ORDER BY s.COUNT_WRITE DESC
      SQL

      indexes = results.map do |row|
        table = row["table_name"] || row["TABLE_NAME"]
        index_name = row["index_name"] || row["INDEX_NAME"]
        {
          table: table,
          index_name: index_name,
          reads: (row["reads"] || row["READS"] || 0).to_i,
          writes: (row["writes"] || row["WRITES"] || 0).to_i,
          table_rows: (row["table_rows"] || row["TABLE_ROWS"] || 0).to_i,
          drop_sql: "ALTER TABLE `#{table}` DROP INDEX `#{index_name}`;",
        }
      end

      render(json: indexes)
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Unused index detection requires performance_schema. #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end

    def server_overview
      connection = ActiveRecord::Base.connection

      # Global status variables
      status_rows = connection.exec_query("SHOW GLOBAL STATUS")
      status = {}
      status_rows.each { |r| status[(r["Variable_name"] || r["variable_name"]).to_s] = (r["Value"] || r["value"]).to_s }

      # Global variables
      vars_rows = connection.exec_query("SHOW GLOBAL VARIABLES")
      vars = {}
      vars_rows.each { |r| vars[(r["Variable_name"] || r["variable_name"]).to_s] = (r["Value"] || r["value"]).to_s }

      version = connection.select_value("SELECT VERSION()")
      uptime_seconds = status["Uptime"].to_i

      days = uptime_seconds / 86400
      hours = (uptime_seconds % 86400) / 3600
      minutes = (uptime_seconds % 3600) / 60

      max_conn = vars["max_connections"].to_i
      current_conn = status["Threads_connected"].to_i
      conn_pct = max_conn > 0 ? ((current_conn.to_f / max_conn) * 100).round(1) : 0

      buffer_pool_bytes = vars["innodb_buffer_pool_size"].to_i
      buffer_pool_mb = (buffer_pool_bytes / 1024.0 / 1024.0).round(1)

      # Buffer pool hit rate
      reads = status["Innodb_buffer_pool_read_requests"].to_f
      disk_reads = status["Innodb_buffer_pool_reads"].to_f
      hit_rate = reads > 0 ? (((reads - disk_reads) / reads) * 100).round(2) : 0

      # Tmp tables
      tmp_tables = status["Created_tmp_tables"].to_i
      tmp_disk_tables = status["Created_tmp_disk_tables"].to_i
      tmp_disk_pct = tmp_tables > 0 ? ((tmp_disk_tables.to_f / tmp_tables) * 100).round(1) : 0

      # Slow queries from MySQL's own counter
      slow_queries = status["Slow_queries"].to_i

      # Questions (total queries)
      questions = status["Questions"].to_i
      qps = uptime_seconds > 0 ? (questions.to_f / uptime_seconds).round(1) : 0

      render(json: {
        server: {
          version: version,
          uptime: "#{days}d #{hours}h #{minutes}m",
          uptime_seconds: uptime_seconds,
        },
        connections: {
          max: max_conn,
          current: current_conn,
          usage_pct: conn_pct,
          threads_running: status["Threads_running"].to_i,
          threads_cached: status["Threads_cached"].to_i,
          threads_created: status["Threads_created"].to_i,
          aborted_connects: status["Aborted_connects"].to_i,
          aborted_clients: status["Aborted_clients"].to_i,
          max_used: status["Max_used_connections"].to_i,
        },
        innodb: {
          buffer_pool_mb: buffer_pool_mb,
          buffer_pool_hit_rate: hit_rate,
          buffer_pool_pages_dirty: status["Innodb_buffer_pool_pages_dirty"].to_i,
          buffer_pool_pages_free: status["Innodb_buffer_pool_pages_free"].to_i,
          buffer_pool_pages_total: status["Innodb_buffer_pool_pages_total"].to_i,
          row_lock_waits: status["Innodb_row_lock_waits"].to_i,
          row_lock_time_ms: status["Innodb_row_lock_time"].to_f.round(0),
        },
        queries: {
          questions: questions,
          qps: qps,
          slow_queries: slow_queries,
          tmp_tables: tmp_tables,
          tmp_disk_tables: tmp_disk_tables,
          tmp_disk_pct: tmp_disk_pct,
          select_full_join: status["Select_full_join"].to_i,
          sort_merge_passes: status["Sort_merge_passes"].to_i,
        },
      })
    rescue => e
      render(json: { error: "Failed to load server overview: #{e.message}" }, status: :unprocessable_entity)
    end
  end
end
