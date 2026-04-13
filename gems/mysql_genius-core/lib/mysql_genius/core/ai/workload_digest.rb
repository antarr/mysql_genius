# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Produces a high-level executive summary of the query workload by
      # pulling the top statements from performance_schema and asking the
      # LLM to characterize read/write ratio, access patterns, waste
      # concentration, and highest-leverage optimization opportunities.
      #
      # Construct with:
      #   connection - a Core::Connection implementation
      #   client     - a Core::Ai::Client
      #   config     - the Core::Ai::Config
      #
      # Call:
      #   .call() -> Hash with "digest" key containing markdown analysis
      class WorkloadDigest
        TOP_N = 30

        def initialize(connection, client, config)
          @connection = connection
          @client = client
          @config = config
        end

        def call
          stats = Analysis::QueryStats.new(@connection).call(sort: "total_time", limit: TOP_N)
          formatted = format_stats(stats)

          messages = [
            { role: "system", content: system_prompt },
            { role: "user", content: user_prompt(formatted, stats.length) },
          ]

          @client.chat(messages: messages)
        end

        private

        def system_prompt
          prompt = <<~PROMPT
            You are a MySQL performance analyst producing an executive workload digest.
          PROMPT

          if @config.domain_context && !@config.domain_context.empty?
            prompt += <<~PROMPT

              Domain context:
              #{@config.domain_context}
            PROMPT
          end

          prompt += <<~PROMPT

            Analyze the provided query workload data and produce a concise executive summary covering:
            1. Read vs write ratio and overall workload characterization
            2. Access patterns (point lookups, range scans, full table scans, aggregations)
            3. Waste concentration — which queries examine many rows but return few
            4. Top 3 highest-leverage changes that would improve overall performance

            Respond with JSON: {"digest": "markdown-formatted workload analysis"}
          PROMPT

          prompt
        end

        def user_prompt(formatted_stats, count)
          <<~PROMPT
            Top #{count} queries by total execution time:

            #{formatted_stats}
          PROMPT
        end

        def format_stats(stats)
          stats.map.with_index(1) do |s, i|
            "#{i}. SQL: #{s[:sql]}\n   " \
              "calls=#{s[:calls]}, avg_time_ms=#{s[:avg_time_ms]}, " \
              "rows_ratio=#{s[:rows_ratio]}, tmp_disk_tables=#{s[:tmp_disk_tables]}"
          end.join("\n")
        end
      end
    end
  end
end
