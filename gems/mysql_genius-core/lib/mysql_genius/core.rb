# frozen_string_literal: true

require "mysql_genius/core/version"

module MysqlGenius
  # The Rails-free core library. Consumed by both the `mysql_genius` Rails
  # adapter gem and (from Phase 2 onward) the `mysql_genius-desktop` gem.
  #
  # See `docs/superpowers/specs/2026-04-10-desktop-app-design.md` for the
  # overall design.
  module Core
    class Error < StandardError; end

    class << self
      # Absolute path to the shared ERB template directory. Adapters
      # register this path with their view loader:
      #
      #   Rails:   engine.config.paths["app/views"] << MysqlGenius::Core.views_path
      #   Sinatra: set :views, MysqlGenius::Core.views_path
      def views_path
        File.expand_path("core/views", __dir__)
      end
    end
  end
end

require "mysql_genius/core/result"
require "mysql_genius/core/server_info"
require "mysql_genius/core/column_definition"
require "mysql_genius/core/index_definition"
require "mysql_genius/core/sql_validator"
require "mysql_genius/core/connection"
require "mysql_genius/core/connection/fake_adapter"
require "mysql_genius/core/ai/config"
require "mysql_genius/core/ai/client"
require "mysql_genius/core/ai/suggestion"
require "mysql_genius/core/ai/optimization"
require "mysql_genius/core/ai/schema_context_builder"
require "mysql_genius/core/ai/describe_query"
require "mysql_genius/core/ai/schema_review"
require "mysql_genius/core/ai/rewrite_query"
require "mysql_genius/core/ai/index_advisor"
require "mysql_genius/core/ai/migration_risk"
require "mysql_genius/core/ai/variable_reviewer"
require "mysql_genius/core/ai/connection_advisor"
require "mysql_genius/core/ai/workload_digest"
require "mysql_genius/core/ai/innodb_interpreter"
require "mysql_genius/core/analysis/table_sizes"
require "mysql_genius/core/analysis/duplicate_indexes"
require "mysql_genius/core/analysis/query_stats"
require "mysql_genius/core/analysis/unused_indexes"
require "mysql_genius/core/analysis/server_overview"
require "mysql_genius/core/analysis/columns"
require "mysql_genius/core/analysis/stats_history"
require "mysql_genius/core/analysis/stats_collector"
require "mysql_genius/core/execution_result"
require "mysql_genius/core/query_runner/config"
require "mysql_genius/core/query_runner"
require "mysql_genius/core/query_explainer"
