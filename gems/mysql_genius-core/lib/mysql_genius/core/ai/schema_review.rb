# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Reviews a schema for anti-patterns. Takes a specific table name
      # (or nil to review the top 20 queryable tables).
      class SchemaReview
        def initialize(client, config, connection)
          @client = client
          @config = config
          @connection = connection
        end

        def call(table)
          tables_to_review = table.nil? || table.to_s.empty? ? @connection.tables.first(20) : [table]
          schema_desc = SchemaContextBuilder.new(@connection).call(tables_to_review, detail: :basic)

          messages = [
            { role: "system", content: system_prompt },
            { role: "user",   content: schema_desc },
          ]
          @client.chat(messages: messages)
        end

        private

        def system_prompt
          <<~PROMPT
            You are a MySQL schema reviewer. Analyze the following schema and identify anti-patterns and improvement opportunities. Look for:
            - Inappropriate column types (VARCHAR(255) for short values, TEXT where VARCHAR suffices, INT for booleans)
            - Missing indexes on foreign key columns or frequently filtered columns
            - Missing NOT NULL constraints where NULLs are unlikely
            - ENUM columns that should be lookup tables
            - Missing created_at/updated_at timestamps
            - Tables without a PRIMARY KEY
            - Overly wide indexes or redundant indexes
            - Column naming inconsistencies
            #{@config.domain_context}
            Respond with JSON: {"findings": "markdown-formatted findings organized by severity (Critical, Warning, Suggestion). Include specific ALTER TABLE statements where applicable."}
          PROMPT
        end
      end
    end
  end
end
