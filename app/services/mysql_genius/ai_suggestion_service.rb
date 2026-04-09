module MysqlGenius
  class AiSuggestionService
    def call(user_prompt, allowed_tables)
      schema = build_schema_description(allowed_tables)
      messages = [
        { role: "system", content: system_prompt(schema) },
        { role: "user", content: user_prompt }
      ]

      AiClient.new.chat(messages: messages)
    end

    private

    def system_prompt(schema_description)
      custom_context = MysqlGenius.configuration.ai_system_context

      prompt = <<~PROMPT
        You are a SQL query assistant for a MySQL database.
      PROMPT

      if custom_context && !custom_context.empty?
        prompt += <<~PROMPT

          Domain context:
          #{custom_context}
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
      connection = ActiveRecord::Base.connection
      allowed_tables.map do |table|
        next unless connection.tables.include?(table)
        columns = connection.columns(table).map { |c| "#{c.name} (#{c.type})" }
        "#{table}: #{columns.join(', ')}"
      end.compact.join("\n")
    end
  end
end
