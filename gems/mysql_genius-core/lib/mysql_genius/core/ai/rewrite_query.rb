# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Suggests a rewritten version of a SQL query based on the schema
      # context of the tables it references.
      class RewriteQuery
        def initialize(client, config, connection)
          @client = client
          @config = config
          @connection = connection
        end

        def call(sql)
          tables = SqlValidator.extract_table_references(sql, @connection)
          schema = SchemaContextBuilder.new(@connection).call(tables, detail: :basic)

          messages = [
            { role: "system", content: system_prompt(schema) },
            { role: "user",   content: sql },
          ]
          @client.chat(messages: messages)
        end

        private

        def system_prompt(schema)
          <<~PROMPT
            You are a MySQL query rewrite expert. Analyze the SQL for anti-patterns and suggest a rewritten version. Look for:
            - SELECT * when specific columns would suffice
            - Correlated subqueries that could be JOINs
            - OR conditions preventing index use (suggest UNION ALL)
            - LIKE '%prefix' patterns (leading wildcard)
            - Implicit type conversions in WHERE clauses
            - NOT IN with NULLable columns (suggest NOT EXISTS)
            - ORDER BY on non-indexed columns with LIMIT
            - Unnecessary DISTINCT
            - Functions on indexed columns in WHERE (e.g., DATE(created_at) instead of range)

            Available schema:
            #{schema}
            #{@config.domain_context}

            Respond with JSON: {"original": "the original SQL", "rewritten": "the improved SQL", "changes": "markdown list of each change and why it helps"}
          PROMPT
        end
      end
    end
  end
end
