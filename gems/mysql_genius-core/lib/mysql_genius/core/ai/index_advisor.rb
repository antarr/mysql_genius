# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      class IndexAdvisor
        def initialize(client, config, connection)
          @client = client
          @config = config
          @connection = connection
        end

        def call(sql, explain_rows)
          tables = SqlValidator.extract_table_references(sql, @connection)
          schema = SchemaContextBuilder.new(@connection).call(tables, detail: :with_cardinality)
          explain_text = explain_rows.map { |row| row.join(" | ") }.join("\n")

          messages = [
            { role: "system", content: system_prompt },
            { role: "user",   content: "Query:\n#{sql}\n\nEXPLAIN:\n#{explain_text}\n\nSchema:\n#{schema}" },
          ]
          @client.chat(messages: messages)
        end

        private

        def system_prompt
          <<~PROMPT
            You are a MySQL index advisor. Given a query, its EXPLAIN output, and current index/cardinality information, suggest optimal indexes. Consider:
            - Composite index column ordering (most selective first, or matching query order)
            - Covering indexes to avoid table lookups
            - Partial indexes for long string columns
            - Write-side costs (if this is a high-write table, note the INSERT/UPDATE overhead)
            - Whether existing indexes could be extended rather than creating new ones
            #{@config.domain_context}

            Respond with JSON: {"indexes": "markdown-formatted recommendations with exact CREATE INDEX statements, rationale for column ordering, and estimated impact. Include any indexes that should be DROPPED as part of the change."}
          PROMPT
        end
      end
    end
  end
end
