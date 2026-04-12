# frozen_string_literal: true

module MysqlGenius
  module Desktop
    PATHS = {
      columns: "/columns",
      execute: "/execute",
      explain: "/explain",
      suggest: "/suggest",
      optimize: "/optimize",
      slow_queries: "/slow_queries",
      duplicate_indexes: "/duplicate_indexes",
      table_sizes: "/table_sizes",
      query_stats: "/query_stats",
      unused_indexes: "/unused_indexes",
      server_overview: "/server_overview",
      describe_query: "/describe_query",
      schema_review: "/schema_review",
      rewrite_query: "/rewrite_query",
      index_advisor: "/index_advisor",
      anomaly_detection: "/anomaly_detection",
      root_cause: "/root_cause",
      migration_risk: "/migration_risk",
      root: "/",
      query_detail: "/queries/",
      query_history: "/api/query_history/",
    }.freeze
  end
end
