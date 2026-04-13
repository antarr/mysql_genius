# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Diagnoses connection pool health by gathering connection-related
      # metrics from SHOW GLOBAL STATUS and SHOW GLOBAL VARIABLES, then
      # asking the LLM to distinguish between pool misconfiguration,
      # connection leaks, missing pooling, and traffic saturation.
      class ConnectionAdvisor
        STATUS_KEYS = [
          "Threads_connected",
          "Threads_running",
          "Max_used_connections",
          "Aborted_connects",
          "Aborted_clients",
          "Connections",
          "Threads_created",
        ].freeze

        VARIABLE_KEYS = [
          "max_connections",
          "wait_timeout",
          "interactive_timeout",
          "thread_cache_size",
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
            .select { |row| VARIABLE_KEYS.include?(row[0]) }
            .map { |row| [row[0], row[1]] }
        end

        def fetch_status
          result = @connection.exec_query("SHOW GLOBAL STATUS")
          result.rows
            .select { |row| STATUS_KEYS.include?(row[0]) }
            .map { |row| [row[0], row[1]] }
        end

        def system_prompt
          <<~PROMPT
            You are a MySQL connection health advisor. Analyze the connection-related variables and status counters below, then diagnose the connection health and provide specific recommendations. Consider:
            - Connection utilization: Max_used_connections vs max_connections (target: stay below 80%)
            - Aborted connections: Aborted_connects indicates authentication failures or client errors; Aborted_clients indicates clients disconnecting without proper cleanup
            - Thread cache efficiency: Threads_created vs Connections (high ratio means thread_cache_size is too small)
            - Timeout configuration: wait_timeout and interactive_timeout impact how long idle connections persist
            - Connection leak indicators: high Threads_connected with low Threads_running suggests idle connection accumulation
            - Traffic saturation: high Threads_running relative to CPU cores suggests query contention

            Distinguish between these root causes:
            1. Pool misconfiguration (max_connections too low/high, bad timeout values)
            2. Connection leaks (growing Threads_connected, high Aborted_clients)
            3. Missing connection pooling (high Connections with short-lived threads)
            4. Traffic saturation (high Threads_running, query contention)
            #{@config.domain_context}
            Respond with JSON: {"diagnosis": "markdown analysis distinguishing between pool misconfiguration, connection leaks, missing pooling, and traffic saturation, with specific variable recommendations and values"}
          PROMPT
        end

        def user_prompt(variables, status)
          lines = ["== Connection Variables =="]
          variables.each { |name, value| lines << "#{name} = #{value}" }
          lines << ""
          lines << "== Connection Status Counters =="
          status.each { |name, value| lines << "#{name} = #{value}" }
          lines.join("\n")
        end
      end
    end
  end
end
