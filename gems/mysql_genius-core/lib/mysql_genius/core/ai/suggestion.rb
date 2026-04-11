# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Turns a natural-language prompt + a list of allowed tables into
      # a SELECT query via the AI client.
      #
      # Construct with:
      #   connection - a Core::Connection implementation
      #   client     - a Core::Ai::Client (pre-built with the same config)
      #   config     - the Core::Ai::Config (used for system_context)
      #
      # Call:
      #   .call(user_prompt, allowed_tables)  -> Hash with "sql" and "explanation"
      class Suggestion
        def initialize(connection, client, config)
          @connection = connection
          @client = client
          @config = config
        end

        def call(user_prompt, allowed_tables)
          schema = build_schema_description(allowed_tables)
          messages = [
            { role: "system", content: system_prompt(schema) },
            { role: "user", content: user_prompt },
          ]

          @client.chat(messages: messages)
        end

        private

        def system_prompt(schema_description)
          prompt = <<~PROMPT
            You are a SQL query assistant for a MySQL database.
          PROMPT

          if @config.system_context && !@config.system_context.empty?
            prompt += <<~PROMPT

              Domain context:
              #{@config.system_context}
            PROMPT
          end

          prompt += <<~PROMPT

            Rules:
            - Only generate SELECT statements. Never generate INSERT, UPDATE, DELETE, or any other mutation.
            - Only reference the tables and columns listed in the schema below. Do not guess or invent column names.
            - Use backticks for table and column names.
            - Include a LIMIT 100 unless the user specifies otherwise.

            Available schema:
            #{schema_description}

            Respond with JSON: {"sql": "the SQL query", "explanation": "brief explanation of what the query does"}
          PROMPT

          prompt
        end

        def build_schema_description(allowed_tables)
          allowed_tables.map do |table|
            next unless @connection.tables.include?(table)

            columns = @connection.columns_for(table).map { |c| "#{c.name} (#{c.type})" }
            "#{table}: #{columns.join(", ")}"
          end.compact.join("\n")
        end
      end
    end
  end
end
