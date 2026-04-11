# frozen_string_literal: true

require "mysql_genius/core"

module MysqlGenius
  module Core
    module Connection
      # Wraps an ActiveRecord::Base.connection and implements the
      # Core::Connection contract. Lives in the mysql_genius (Rails
      # adapter) gem because it depends on ActiveRecord; the contract
      # itself lives in mysql_genius-core.
      class ActiveRecordAdapter
        def initialize(ar_connection)
          @ar = ar_connection
        end

        def exec_query(sql, binds: [])
          _ = binds
          ar_result = @ar.exec_query(sql)
          Core::Result.new(columns: ar_result.columns, rows: ar_result.rows)
        end

        def select_value(sql)
          @ar.select_value(sql)
        end

        def server_version
          Core::ServerInfo.parse(@ar.select_value("SELECT VERSION()").to_s)
        end

        def current_database
          @ar.current_database
        end

        def quote(value)
          @ar.quote(value)
        end

        def quote_table_name(name)
          @ar.quote_table_name(name)
        end

        def tables
          @ar.tables
        end

        def columns_for(table)
          pk = @ar.primary_key(table)
          @ar.columns(table).map do |c|
            Core::ColumnDefinition.new(
              name: c.name,
              type: c.type,
              sql_type: c.sql_type,
              null: c.null,
              default: c.default,
              primary_key: c.name == pk,
            )
          end
        end

        def indexes_for(table)
          @ar.indexes(table).map do |idx|
            Core::IndexDefinition.new(name: idx.name, columns: idx.columns, unique: idx.unique)
          end
        end

        def primary_key(table)
          @ar.primary_key(table)
        end

        def close
          nil
        end
      end
    end
  end
end
