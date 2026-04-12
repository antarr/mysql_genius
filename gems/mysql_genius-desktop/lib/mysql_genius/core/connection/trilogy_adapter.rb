# frozen_string_literal: true

require "mysql_genius/core"

module MysqlGenius
  module Core
    module Connection
      # Translation layer between the Core::Connection contract and
      # Trilogy::Client. Stateless — all lifecycle (open/close/retry) is
      # owned by MysqlGenius::Desktop::ActiveSession.
      class TrilogyAdapter
        def initialize(client)
          @client = client
        end

        def exec_query(sql, binds: [])
          _ = binds
          result = @client.query(sql)
          Core::Result.new(columns: result.fields, rows: result.rows)
        end

        def select_value(sql)
          rows = @client.query(sql).rows
          rows.empty? ? nil : rows.first.first
        end

        def server_version
          Core::ServerInfo.parse(select_value("SELECT VERSION()").to_s)
        end

        def current_database
          select_value("SELECT DATABASE()")
        end

        def quote(value)
          "'#{@client.escape(value.to_s)}'"
        end

        def quote_table_name(name)
          "`#{name.to_s.gsub("`", "``")}`"
        end

        def tables
          db = current_database
          sql = <<~SQL.strip
            SELECT TABLE_NAME FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '#{@client.escape(db.to_s)}' AND TABLE_TYPE = 'BASE TABLE'
            ORDER BY TABLE_NAME
          SQL
          @client.query(sql).rows.map(&:first)
        end

        def columns_for(table)
          db = current_database
          sql = <<~SQL.strip
            SELECT COLUMN_NAME, COLUMN_TYPE, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = '#{@client.escape(db.to_s)}'
              AND TABLE_NAME = '#{@client.escape(table.to_s)}'
            ORDER BY ORDINAL_POSITION
          SQL
          @client.query(sql).rows.map do |row|
            name, column_type, data_type, is_nullable, default, column_key = row
            Core::ColumnDefinition.new(
              name:        name,
              sql_type:    column_type,
              type:        data_type.to_s.downcase.to_sym,
              null:        is_nullable == "YES",
              default:     default,
              primary_key: column_key == "PRI",
            )
          end
        end

        def indexes_for(table)
          db = current_database
          sql = <<~SQL.strip
            SELECT INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX, NON_UNIQUE
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = '#{@client.escape(db.to_s)}'
              AND TABLE_NAME = '#{@client.escape(table.to_s)}'
            ORDER BY INDEX_NAME, SEQ_IN_INDEX
          SQL
          grouped = @client.query(sql).rows.group_by { |row| row[0] }
          grouped.sort_by { |index_name, _| index_name }.map do |index_name, rows|
            Core::IndexDefinition.new(
              name:    index_name,
              columns: rows.map { |r| r[1] },
              unique:  rows.first[3].to_i.zero?,
            )
          end
        end

        def primary_key(table)
          db = current_database
          sql = <<~SQL.strip
            SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE
            WHERE TABLE_SCHEMA = '#{@client.escape(db.to_s)}'
              AND TABLE_NAME = '#{@client.escape(table.to_s)}'
              AND CONSTRAINT_NAME = 'PRIMARY'
              AND ORDINAL_POSITION = 1
          SQL
          @client.query(sql).rows.first&.first
        end

        def close
          @client.close
          nil
        end
      end
    end
  end
end
