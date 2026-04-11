# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Collects a dashboard-worthy snapshot of server state by combining
      # SHOW GLOBAL STATUS, SHOW GLOBAL VARIABLES, and SELECT VERSION().
      # Computes derived metrics (uptime formatting, connection usage
      # percentage, buffer pool hit rate, tmp-disk percentage, QPS).
      #
      # Returns a nested hash with four top-level sections: server,
      # connections, innodb, queries. Errors propagate; the caller
      # decides how to render failure.
      class ServerOverview
        def initialize(connection)
          @connection = connection
        end

        def call
          status = load_status
          vars = load_variables
          version = @connection.select_value("SELECT VERSION()")

          uptime_seconds = status["Uptime"].to_i
          {
            server: server_block(version, uptime_seconds),
            connections: connections_block(status, vars),
            innodb: innodb_block(status, vars),
            queries: queries_block(status, uptime_seconds),
          }
        end

        private

        def load_status
          result = @connection.exec_query("SHOW GLOBAL STATUS")
          result.to_hashes.each_with_object({}) do |row, acc|
            name = (row["Variable_name"] || row["variable_name"]).to_s
            value = (row["Value"] || row["value"]).to_s
            acc[name] = value
          end
        end

        def load_variables
          result = @connection.exec_query("SHOW GLOBAL VARIABLES")
          result.to_hashes.each_with_object({}) do |row, acc|
            name = (row["Variable_name"] || row["variable_name"]).to_s
            value = (row["Value"] || row["value"]).to_s
            acc[name] = value
          end
        end

        def server_block(version, uptime_seconds)
          days = uptime_seconds / 86_400
          hours = (uptime_seconds % 86_400) / 3600
          minutes = (uptime_seconds % 3600) / 60

          {
            version: version,
            uptime: "#{days}d #{hours}h #{minutes}m",
            uptime_seconds: uptime_seconds,
          }
        end

        def connections_block(status, vars)
          max_conn = vars["max_connections"].to_i
          current_conn = status["Threads_connected"].to_i
          usage_pct = max_conn.positive? ? ((current_conn.to_f / max_conn) * 100).round(1) : 0

          {
            max: max_conn,
            current: current_conn,
            usage_pct: usage_pct,
            threads_running: status["Threads_running"].to_i,
            threads_cached: status["Threads_cached"].to_i,
            threads_created: status["Threads_created"].to_i,
            aborted_connects: status["Aborted_connects"].to_i,
            aborted_clients: status["Aborted_clients"].to_i,
            max_used: status["Max_used_connections"].to_i,
          }
        end

        def innodb_block(status, vars)
          buffer_pool_bytes = vars["innodb_buffer_pool_size"].to_i
          buffer_pool_mb = (buffer_pool_bytes / 1024.0 / 1024.0).round(1)

          reads = status["Innodb_buffer_pool_read_requests"].to_f
          disk_reads = status["Innodb_buffer_pool_reads"].to_f
          hit_rate = reads.positive? ? (((reads - disk_reads) / reads) * 100).round(2) : 0

          {
            buffer_pool_mb: buffer_pool_mb,
            buffer_pool_hit_rate: hit_rate,
            buffer_pool_pages_dirty: status["Innodb_buffer_pool_pages_dirty"].to_i,
            buffer_pool_pages_free: status["Innodb_buffer_pool_pages_free"].to_i,
            buffer_pool_pages_total: status["Innodb_buffer_pool_pages_total"].to_i,
            row_lock_waits: status["Innodb_row_lock_waits"].to_i,
            row_lock_time_ms: status["Innodb_row_lock_time"].to_f.round(0),
          }
        end

        def queries_block(status, uptime_seconds)
          tmp_tables = status["Created_tmp_tables"].to_i
          tmp_disk_tables = status["Created_tmp_disk_tables"].to_i
          tmp_disk_pct = tmp_tables.positive? ? ((tmp_disk_tables.to_f / tmp_tables) * 100).round(1) : 0

          questions = status["Questions"].to_i
          qps = uptime_seconds.positive? ? (questions.to_f / uptime_seconds).round(1) : 0

          {
            questions: questions,
            qps: qps,
            slow_queries: status["Slow_queries"].to_i,
            tmp_tables: tmp_tables,
            tmp_disk_tables: tmp_disk_tables,
            tmp_disk_pct: tmp_disk_pct,
            select_full_join: status["Select_full_join"].to_i,
            sort_merge_passes: status["Sort_merge_passes"].to_i,
          }
        end
      end
    end
  end
end
