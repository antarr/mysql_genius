# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      class MigrationRisk
        def initialize(client, config, connection)
          @client = client
          @config = config
          @connection = connection
        end

        def call(migration_sql)
          tables = extract_table_names(migration_sql)
          schema = SchemaContextBuilder.new(@connection).call(tables, detail: :basic)
          schema_text = schema.to_s.empty? ? "Could not determine" : schema

          messages = [
            { role: "system", content: system_prompt },
            { role: "user",   content: "Migration:\n#{migration_sql}\n\nAffected Tables:\n#{schema_text}" },
          ]
          @client.chat(messages: messages)
        end

        private

        def extract_table_names(migration_sql)
          # Match Rails migration helpers and raw SQL ALTER TABLE statements.
          rails_matches = migration_sql.scan(/(?:create_table|add_column|remove_column|add_index|remove_index|rename_column|change_column|alter\s+table)\s+[:"]?(\w+)/i).flatten
          sql_matches   = migration_sql.scan(/ALTER\s+TABLE\s+`?(\w+)`?/i).flatten
          (rails_matches + sql_matches).uniq
        end

        def system_prompt
          <<~PROMPT
            You are a MySQL migration risk assessor. Given a Rails migration or DDL, evaluate:
            1. Will this lock the table? For how long given the row count?
            2. Is this safe to run during traffic, or does it need a maintenance window?
            3. Should pt-online-schema-change or gh-ost be used instead?
            4. Will it break or degrade any of the active queries against this table?
            5. Are there any data loss risks?
            6. What is the recommended deployment strategy?
            #{@config.domain_context}

            Respond with JSON: {"risk_level": "low|medium|high|critical", "assessment": "markdown-formatted risk assessment with specific recommendations and estimated lock duration"}
          PROMPT
        end
      end
    end
  end
end
