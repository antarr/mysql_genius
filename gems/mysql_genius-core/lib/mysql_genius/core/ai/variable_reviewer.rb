# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Reviews MySQL configuration variables against best practices for
      # the observed workload. Gathers SHOW GLOBAL VARIABLES (filtered to
      # ~20 performance-relevant keys) and SHOW GLOBAL STATUS, then asks
      # the LLM to identify misconfigurations.
      class VariableReviewer
        RELEVANT_VARIABLES = [
          "innodb_buffer_pool_size",
          "innodb_log_file_size",
          "innodb_flush_log_at_trx_commit",
          "max_connections",
          "query_cache_type",
          "sort_buffer_size",
          "join_buffer_size",
          "tmp_table_size",
          "max_heap_table_size",
          "thread_cache_size",
          "table_open_cache",
          "innodb_file_per_table",
          "innodb_flush_method",
          "binlog_format",
          "sync_binlog",
          "innodb_io_capacity",
          "innodb_read_io_threads",
          "innodb_write_io_threads",
          "long_query_time",
          "slow_query_log",
          "performance_schema",
        ].freeze

        RELEVANT_STATUS_KEYS = [
          "Innodb_buffer_pool_reads",
          "Innodb_buffer_pool_read_requests",
          "Created_tmp_disk_tables",
          "Created_tmp_tables",
          "Sort_merge_passes",
          "Threads_created",
          "Threads_connected",
          "Max_used_connections",
          "Slow_queries",
          "Questions",
          "Uptime",
        ].freeze

        def initialize(client, config, connection)
          @client = client
          @config = config
          @connection = connection
        end

        def call
          variables = fetch_variables
          status = fetch_status

          messages = [
            { role: "system", content: system_prompt },
            { role: "user",   content: user_prompt(variables, status) },
          ]
          @client.chat(messages: messages)
        end

        private

        def fetch_variables
          result = @connection.exec_query("SHOW GLOBAL VARIABLES")
          result.rows
            .select { |row| RELEVANT_VARIABLES.include?(row[0]) }
            .map { |row| [row[0], row[1]] }
        end

        def fetch_status
          result = @connection.exec_query("SHOW GLOBAL STATUS")
          result.rows
            .select { |row| RELEVANT_STATUS_KEYS.include?(row[0]) }
            .map { |row| [row[0], row[1]] }
        end

        def system_prompt
          <<~PROMPT
            You are a MySQL configuration reviewer. Analyze the server variables and status counters below, then identify misconfigurations and improvement opportunities. Consider:
            - Buffer pool sizing relative to workload (hit rate from status counters)
            - Temporary table spills to disk (tmp_table_size vs Created_tmp_disk_tables)
            - Sort buffer and join buffer sizing
            - Connection pool sizing (max_connections vs Max_used_connections)
            - Thread cache effectiveness
            - InnoDB flush and sync settings for durability vs performance trade-offs
            - Slow query log configuration
            - Binary log format suitability
            #{@config.domain_context}
            Respond with JSON: {"findings": "markdown-formatted analysis organized by severity (Critical, Warning, Suggestion). Include specific SET GLOBAL or my.cnf recommendations with before/after values."}
          PROMPT
        end

        def user_prompt(variables, status)
          lines = ["== Server Variables =="]
          variables.each { |name, value| lines << "#{name} = #{value}" }
          lines << ""
          lines << "== Server Status Counters =="
          status.each { |name, value| lines << "#{name} = #{value}" }
          lines.join("\n")
        end
      end
    end
  end
end
