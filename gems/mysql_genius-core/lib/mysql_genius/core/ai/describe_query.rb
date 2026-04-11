# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Builds and sends a "describe this query" prompt to Core::Ai::Client.
      # Pure function of SQL + config.domain_context — no connection lookup.
      #
      # Extracted from app/controllers/concerns/mysql_genius/ai_features.rb
      # in Phase 2a.
      class DescribeQuery
        def initialize(client, config)
          @client = client
          @config = config
        end

        def call(sql)
          messages = [
            { role: "system", content: system_prompt },
            { role: "user",   content: sql },
          ]
          @client.chat(messages: messages)
        end

        private

        def system_prompt
          <<~PROMPT
            You are a MySQL query explainer. Given a SQL query, explain in plain English:
            1. What the query does (tables involved, joins, filters, aggregations)
            2. How data flows through the query
            3. Any subtle behaviors (implicit type casts, NULL handling in NOT IN, DISTINCT effects, etc.)
            4. Potential performance concerns visible from the SQL structure alone
            #{@config.domain_context}
            Respond with JSON: {"explanation": "your plain-English explanation using markdown formatting"}
          PROMPT
        end
      end
    end
  end
end
