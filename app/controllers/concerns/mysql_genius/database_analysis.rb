# frozen_string_literal: true

module MysqlGenius
  module DatabaseAnalysis
    extend ActiveSupport::Concern

    def duplicate_indexes
      duplicates = MysqlGenius::Core::Analysis::DuplicateIndexes
        .new(rails_connection, blocked_tables: mysql_genius_config.blocked_tables)
        .call
      render(json: duplicates)
    end

    def table_sizes
      tables = MysqlGenius::Core::Analysis::TableSizes.new(rails_connection).call
      render(json: tables)
    end

    def query_stats
      sort = params[:sort].to_s
      limit = params.fetch(:limit, MysqlGenius::Core::Analysis::QueryStats::MAX_LIMIT).to_i
      queries = MysqlGenius::Core::Analysis::QueryStats.new(rails_connection).call(sort: sort, limit: limit)
      render(json: queries)
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Query statistics require performance_schema to be enabled. #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end

    def unused_indexes
      indexes = MysqlGenius::Core::Analysis::UnusedIndexes.new(rails_connection).call
      render(json: indexes)
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Unused index detection requires performance_schema. #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end

    def server_overview
      overview = MysqlGenius::Core::Analysis::ServerOverview.new(rails_connection).call
      render(json: overview)
    rescue => e
      render(json: { error: "Failed to load server overview: #{e.message}" }, status: :unprocessable_entity)
    end
  end
end
