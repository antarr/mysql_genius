module MysqlGenius
  class AiOptimizationService
    def call(sql, explain_rows, allowed_tables)
      schema = build_schema_description(allowed_tables)
      messages = [
        { role: "system", content: system_prompt(schema) },
        { role: "user", content: user_prompt(sql, explain_rows) }
      ]

      AiClient.new.chat(messages: messages)
    end

    private

    def system_prompt(schema_description)
      <<~PROMPT
        You are a MySQL query optimization expert. Given a SQL query and its EXPLAIN output, analyze the query execution plan and provide actionable optimization suggestions.

        Available schema:
        #{schema_description}

        Respond with JSON:
        {
          "suggestions": "Markdown-formatted analysis and suggestions. Include: 1) Summary of current execution plan (scan types, rows examined). 2) Specific recommendations such as indexes to add (provide exact CREATE INDEX statements), query rewrites, or structural changes. 3) Expected impact of each suggestion."
        }
      PROMPT
    end

    def user_prompt(sql, explain_rows)
      <<~PROMPT
        SQL Query:
        #{sql}

        EXPLAIN Output:
        #{format_explain(explain_rows)}
      PROMPT
    end

    def format_explain(explain_rows)
      return explain_rows if explain_rows.is_a?(String)
      explain_rows.map { |row| row.join(" | ") }.join("\n")
    end

    def build_schema_description(allowed_tables)
      connection = ActiveRecord::Base.connection
      allowed_tables.map do |table|
        next unless connection.tables.include?(table)
        columns = connection.columns(table).map { |c| "#{c.name} (#{c.type})" }
        indexes = connection.indexes(table).map { |idx| "#{idx.name}: [#{idx.columns.join(', ')}]#{idx.unique ? ' UNIQUE' : ''}" }
        desc = "#{table}: #{columns.join(', ')}"
        desc += "\n  Indexes: #{indexes.join('; ')}" if indexes.any?
        desc
      end.compact.join("\n")
    end
  end
end
