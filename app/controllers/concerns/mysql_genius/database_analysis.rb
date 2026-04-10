# frozen_string_literal: true

module MysqlGenius
  module DatabaseAnalysis
    extend ActiveSupport::Concern

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
            next unless idx.columns.size <= other.columns.size &&
              other.columns.first(idx.columns.size) == idx.columns &&
              !(idx.unique && !other.unique) # don't drop a unique index covered by a non-unique one

            duplicates << {
              table: table,
              duplicate_index: idx.name,
              duplicate_columns: idx.columns,
              covered_by_index: other.name,
              covered_by_columns: other.columns,
              unique: idx.unique,
            }
          end
        end
      end

      # Deduplicate (A covers B and B covers A when columns are identical -- keep only one)
      seen = Set.new
      duplicates = duplicates.reject do |d|
        key = [d[:table], [d[:duplicate_index], d[:covered_by_index]].sort].flatten.join(":")
        if seen.include?(key)
          true
        else
          (seen.add(key)
           false)
        end
      end

      render(json: duplicates)
    end

    def table_sizes
      connection = ActiveRecord::Base.connection
      db_name = connection.current_database

      results = connection.exec_query(<<~SQL)
        SELECT
          table_name,
          engine,
          table_collation,
          auto_increment,
          update_time,
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
        table_name = row["table_name"] || row["TABLE_NAME"]
        row_count = begin
          connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table_name)}")
        rescue StandardError
          nil
        end

        total_mb = (row["total_mb"] || 0).to_f
        fragmented_mb = (row["fragmented_mb"] || 0).to_f

        {
          table: table_name,
          rows: row_count,
          engine: row["engine"] || row["ENGINE"],
          collation: row["table_collation"] || row["TABLE_COLLATION"],
          auto_increment: row["auto_increment"] || row["AUTO_INCREMENT"],
          updated_at: row["update_time"] || row["UPDATE_TIME"],
          data_mb: (row["data_mb"] || 0).to_f,
          index_mb: (row["index_mb"] || 0).to_f,
          total_mb: total_mb,
          fragmented_mb: fragmented_mb,
          needs_optimize: total_mb > 0 && fragmented_mb > (total_mb * 0.1),
        }
      end

      render(json: tables)
    end

    def query_stats
      connection = ActiveRecord::Base.connection
      sort = ["total_time", "avg_time", "calls", "rows_examined"].include?(params[:sort]) ? params[:sort] : "total_time"

      order_clause = case sort
      when "total_time"    then "SUM_TIMER_WAIT DESC"
      when "avg_time"      then "AVG_TIMER_WAIT DESC"
      when "calls"         then "COUNT_STAR DESC"
      when "rows_examined" then "SUM_ROWS_EXAMINED DESC"
      end

      limit = params.fetch(:limit, 50).to_i.clamp(1, 50)

      results = connection.exec_query(<<~SQL)
        SELECT
          DIGEST_TEXT,
          COUNT_STAR AS calls,
          ROUND(SUM_TIMER_WAIT / 1000000000, 1) AS total_time_ms,
          ROUND(AVG_TIMER_WAIT / 1000000000, 1) AS avg_time_ms,
          ROUND(MAX_TIMER_WAIT / 1000000000, 1) AS max_time_ms,
          SUM_ROWS_EXAMINED AS rows_examined,
          SUM_ROWS_SENT AS rows_sent,
          SUM_CREATED_TMP_DISK_TABLES AS tmp_disk_tables,
          SUM_SORT_ROWS AS sort_rows,
          FIRST_SEEN,
          LAST_SEEN
        FROM performance_schema.events_statements_summary_by_digest
        WHERE SCHEMA_NAME = #{connection.quote(connection.current_database)}
          AND DIGEST_TEXT IS NOT NULL
          AND DIGEST_TEXT NOT LIKE 'EXPLAIN%'
          AND DIGEST_TEXT NOT LIKE '%`information_schema`%'
          AND DIGEST_TEXT NOT LIKE '%`performance_schema`%'
          AND DIGEST_TEXT NOT LIKE '%information_schema.%'
          AND DIGEST_TEXT NOT LIKE '%performance_schema.%'
          AND DIGEST_TEXT NOT LIKE 'SHOW %'
          AND DIGEST_TEXT NOT LIKE 'SET STATEMENT %'
          AND DIGEST_TEXT NOT LIKE 'SELECT VERSION ( )%'
          AND DIGEST_TEXT NOT LIKE 'SELECT @@%'
        ORDER BY #{order_clause}
        LIMIT #{limit}
      SQL

      queries = results.map do |row|
        digest = row["DIGEST_TEXT"] || row["digest_text"] || ""
        calls = (row["calls"] || row["CALLS"] || 0).to_i
        rows_examined = (row["rows_examined"] || row["ROWS_EXAMINED"] || 0).to_i
        rows_sent = (row["rows_sent"] || row["ROWS_SENT"] || 0).to_i
        {
          sql: digest.truncate(500),
          calls: calls,
          total_time_ms: row["total_time_ms"].to_f,
          avg_time_ms: row["avg_time_ms"].to_f,
          max_time_ms: row["max_time_ms"].to_f,
          rows_examined: rows_examined,
          rows_sent: rows_sent,
          rows_ratio: rows_sent > 0 ? (rows_examined.to_f / rows_sent).round(1) : 0,
          tmp_disk_tables: (row["tmp_disk_tables"] || row["TMP_DISK_TABLES"] || 0).to_i,
          sort_rows: (row["sort_rows"] || row["SORT_ROWS"] || 0).to_i,
          first_seen: row["FIRST_SEEN"] || row["first_seen"],
          last_seen: row["LAST_SEEN"] || row["last_seen"],
        }
      end

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
