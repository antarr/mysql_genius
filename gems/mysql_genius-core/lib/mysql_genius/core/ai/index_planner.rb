# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      class IndexPlanner
        def initialize(client, config, connection)
          @client = client
          @config = config
          @connection = connection
        end

        def call(tables = nil)
          target_tables = resolve_tables(tables)
          return { "plan" => "No tables found to analyze." } if target_tables.empty?

          unused = Analysis::UnusedIndexes.new(@connection).call
          duplicates = Analysis::DuplicateIndexes.new(@connection, blocked_tables: []).call
          schema = SchemaContextBuilder.new(@connection).call(target_tables, detail: :with_cardinality)

          index_map = target_tables.to_h do |table|
            [table, @connection.indexes_for(table).map do |idx|
              "#{"UNIQUE " if idx.unique}INDEX #{idx.name} (#{idx.columns.join(", ")})"
            end,]
          end

          messages = [
            { role: "system", content: system_prompt },
            { role: "user",   content: user_prompt(schema, unused, duplicates, index_map) },
          ]
          @client.chat(messages: messages)
        end

        private

        def resolve_tables(tables)
          list = Array(tables).reject { |t| t.to_s.empty? }
          return list unless list.empty?

          top_tables_by_size
        end

        def top_tables_by_size
          db = @connection.current_database
          result = @connection.exec_query(
            "SELECT table_name FROM information_schema.tables " \
              "WHERE table_schema = #{@connection.quote(db)} AND table_type = 'BASE TABLE' " \
              "ORDER BY (data_length + index_length) DESC LIMIT 10",
          )
          result.rows.map(&:first)
        rescue StandardError
          @connection.tables.first(10)
        end

        def user_prompt(schema, unused, duplicates, index_map)
          parts = ["Schema with cardinality:\n#{schema}"]

          if unused.any?
            unused_text = unused.map { |u| "#{u[:table]}.#{u[:index_name]} (reads=#{u[:reads]}, writes=#{u[:writes]})" }
            parts << "Unused indexes (zero reads):\n#{unused_text.join("\n")}"
          end

          if duplicates.any?
            dup_text = duplicates.map do |d|
              "#{d[:table]}: #{d[:duplicate_index]} (#{d[:duplicate_columns].join(", ")}) covered by #{d[:covered_by_index]} (#{d[:covered_by_columns].join(", ")})"
            end
            parts << "Duplicate indexes:\n#{dup_text.join("\n")}"
          end

          index_summary = index_map.map { |table, idxs| "#{table}: #{idxs.any? ? idxs.join("; ") : "NONE"}" }
          parts << "Current indexes per table:\n#{index_summary.join("\n")}"

          parts.join("\n\n")
        end

        def system_prompt
          <<~PROMPT
            You are a MySQL index consolidation planner. Given schema information, unused indexes, duplicate indexes, and current index listings, produce a consolidated optimization plan. For each recommendation:
            - DROP redundant or unused indexes (with exact ALTER TABLE ... DROP INDEX statements)
            - MERGE overlapping indexes into composites where beneficial
            - KEEP indexes that are actively used and well-structured
            - ADD new composite indexes where query patterns suggest benefit
            - Provide rationale for each change and estimated impact on read/write performance
            #{@config.domain_context}
            Respond with JSON: {"plan": "markdown with specific ALTER TABLE / DROP INDEX / CREATE INDEX statements, rationale for each change, and estimated impact"}
          PROMPT
        end
      end
    end
  end
end
