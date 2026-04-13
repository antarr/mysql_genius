# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Groups slow queries by shared root cause so a single fix can improve
      # multiple queries at once. Pulls high-cost statements from
      # performance_schema, extracts referenced tables, builds schema context,
      # and asks the LLM to cluster queries by underlying issue.
      #
      # Construct with:
      #   connection - a Core::Connection implementation
      #   client     - a Core::Ai::Client
      #   config     - the Core::Ai::Config
      #
      # Call:
      #   .call() -> Hash with "groups" key containing markdown analysis
      class PatternGrouper
        QUERY_LIMIT = 30
        ROWS_RATIO_THRESHOLD = 10
        AVG_TIME_THRESHOLD = 50

        def initialize(connection, client, config)
          @connection = connection
          @client = client
          @config = config
        end

        def call
          all_stats = Analysis::QueryStats.new(@connection).call(sort: "total_time", limit: QUERY_LIMIT)
          high_cost = all_stats.select { |s| s[:rows_ratio] > ROWS_RATIO_THRESHOLD || s[:avg_time_ms] > AVG_TIME_THRESHOLD }
          return { "groups" => "No high-cost queries found to analyze." } if high_cost.empty?

          tables = extract_tables(high_cost)
          schema = tables.any? ? SchemaContextBuilder.new(@connection).call(tables, detail: :basic) : ""

          messages = [
            { role: "system", content: system_prompt },
            { role: "user",   content: user_prompt(high_cost, schema) },
          ]

          @client.chat(messages: messages)
        end

        private

        def extract_tables(stats)
          stats.flat_map { |s| SqlValidator.extract_table_references(s[:sql], @connection) }.uniq
        end

        def system_prompt
          prompt = <<~PROMPT
            You are a MySQL performance analyst specializing in root-cause analysis.
          PROMPT

          if @config.domain_context && !@config.domain_context.empty?
            prompt += <<~PROMPT

              Domain context:
              #{@config.domain_context}
            PROMPT
          end

          prompt += <<~PROMPT

            Given a set of high-cost queries and the schema they reference, group them by shared root cause.
            For each group provide:
            1. The shared root cause (e.g., missing index, full table scan, implicit type conversion)
            2. The affected queries (numbered)
            3. A single fix that addresses all queries in the group (with exact SQL: CREATE INDEX, ALTER TABLE, etc.)
            4. Estimated performance impact

            Respond with JSON: {"groups": "markdown with each group showing: the shared root cause, affected queries (numbered), the single fix that addresses all of them (with exact SQL), and estimated impact"}
          PROMPT

          prompt
        end

        def user_prompt(stats, schema)
          formatted = stats.map.with_index(1) do |s, i|
            "#{i}. SQL: #{s[:sql]}\n   " \
              "calls=#{s[:calls]}, avg_time_ms=#{s[:avg_time_ms]}, " \
              "rows_ratio=#{s[:rows_ratio]}, rows_examined=#{s[:rows_examined]}, " \
              "tmp_disk_tables=#{s[:tmp_disk_tables]}"
          end.join("\n")

          parts = ["High-cost queries (rows_ratio > #{ROWS_RATIO_THRESHOLD} OR avg_time_ms > #{AVG_TIME_THRESHOLD}):\n\n#{formatted}"]
          parts << "Schema context:\n#{schema}" unless schema.empty?
          parts.join("\n\n")
        end
      end
    end
  end
end
