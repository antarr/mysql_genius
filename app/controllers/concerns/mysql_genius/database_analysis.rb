# frozen_string_literal: true

module MysqlGenius
  module DatabaseAnalysis
    extend ActiveSupport::Concern

    def duplicate_indexes
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      duplicates = MysqlGenius::Core::Analysis::DuplicateIndexes
        .new(connection, blocked_tables: mysql_genius_config.blocked_tables)
        .call
      render(json: duplicates)
    end

    def table_sizes
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      tables = MysqlGenius::Core::Analysis::TableSizes.new(connection).call
      render(json: tables)
    end

    def query_stats
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      sort = params[:sort].to_s
      limit = params.fetch(:limit, MysqlGenius::Core::Analysis::QueryStats::MAX_LIMIT).to_i
      queries = MysqlGenius::Core::Analysis::QueryStats.new(connection).call(sort: sort, limit: limit)
      render(json: queries)
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Query statistics require performance_schema to be enabled. #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end

    def unused_indexes
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      indexes = MysqlGenius::Core::Analysis::UnusedIndexes.new(connection).call
      render(json: indexes)
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Unused index detection requires performance_schema. #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end

    def server_overview
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      overview = MysqlGenius::Core::Analysis::ServerOverview.new(connection).call
      render(json: overview)
    rescue => e
      render(json: { error: "Failed to load server overview: #{e.message}" }, status: :unprocessable_entity)
    end
  end
end
