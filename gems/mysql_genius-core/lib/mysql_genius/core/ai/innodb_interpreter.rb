# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Interprets SHOW ENGINE INNODB STATUS output in plain English.
      # Combines the raw InnoDB status text with key metrics from
      # ServerOverview to give the LLM full context for its analysis.
      class InnodbInterpreter
        MAX_STATUS_LENGTH = 4000

        def initialize(client, config, connection)
          @client = client
          @config = config
          @connection = connection
        end

        def call
          status_text = fetch_innodb_status
          metrics = fetch_innodb_metrics

          messages = [
            { role: "system", content: system_prompt },
            { role: "user",   content: user_prompt(status_text, metrics) },
          ]
          @client.chat(messages: messages)
        end

        private

        def fetch_innodb_status
          result = @connection.exec_query("SHOW ENGINE INNODB STATUS")
          text = result.rows.first&.dig(2).to_s
          text.length > MAX_STATUS_LENGTH ? text[0, MAX_STATUS_LENGTH] : text
        end

        def fetch_innodb_metrics
          overview = Analysis::ServerOverview.new(@connection).call
          overview[:innodb]
        end

        def system_prompt
          <<~PROMPT
            You are a MySQL InnoDB internals expert. Analyze the SHOW ENGINE INNODB STATUS output and the supplementary metrics below. Provide a plain-English interpretation organized by these sections:
            - **Deadlocks**: recent deadlock information, lock wait chains, affected transactions
            - **Transaction History**: history list length, purge lag, long-running transactions
            - **Buffer Pool**: hit rate, dirty page ratio, free pages, eviction pressure
            - **I/O**: pending reads/writes, log sequence numbers, checkpoint age, log sizing adequacy
            - **Semaphores**: mutex/rw-lock waits, spin rounds, OS waits indicating contention

            For each section, explain what the numbers mean in practical terms and recommend specific actions if problems are detected.
            #{@config.domain_context}
            Respond with JSON: {"findings": "markdown analysis organized by: Deadlocks, Transaction History, Buffer Pool, I/O, Semaphores. Each section should include current state assessment, risk level, and actionable recommendations."}
          PROMPT
        end

        def user_prompt(status_text, metrics)
          lines = ["== SHOW ENGINE INNODB STATUS =="]
          lines << status_text
          lines << ""
          lines << "== InnoDB Metrics Summary =="
          lines << "Buffer Pool Size: #{metrics[:buffer_pool_mb]} MB"
          lines << "Buffer Pool Hit Rate: #{metrics[:buffer_pool_hit_rate]}%"
          lines << "Dirty Pages: #{metrics[:buffer_pool_pages_dirty]}"
          lines << "Free Pages: #{metrics[:buffer_pool_pages_free]}"
          lines << "Total Pages: #{metrics[:buffer_pool_pages_total]}"
          lines << "Row Lock Waits: #{metrics[:row_lock_waits]}"
          lines << "Row Lock Time (ms): #{metrics[:row_lock_time_ms]}"
          lines.join("\n")
        end
      end
    end
  end
end
