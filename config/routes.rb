# frozen_string_literal: true

MysqlGenius::Engine.routes.draw do
  # Root of the mount: redirect to the default database's dashboard. When no
  # MySQL connections are discovered from config/database.yml, send the user
  # to the setup page instead so they get actionable instructions.
  root to: redirect { |_params, req|
    default = MysqlGenius.database_registry.default_key
    default ? "#{req.script_name}/#{default}" : "#{req.script_name}/setup"
  }

  # Setup / no-connection-found page. Lives outside the :database_id scope
  # because it's rendered exactly when no database can be selected.
  get "setup", to: "queries#setup", as: :setup

  # All dashboard and API routes are scoped by the database key. Route names
  # use the `database_` prefix to avoid colliding with top-level helpers.
  scope ":database_id", as: :database do
    root to: "queries#index"

    get  "columns",      to: "queries#columns"
    post "execute",      to: "queries#execute"
    post "explain",      to: "queries#explain"
    get  "queries/:digest", to: "queries#query_detail", as: "query_detail"
    get  "api/query_history/:digest", to: "queries#query_history", as: "query_history"
    post "suggest",      to: "queries#suggest"
    post "optimize",     to: "queries#optimize"
    get  "slow_queries",      to: "queries#slow_queries"
    get  "duplicate_indexes", to: "queries#duplicate_indexes"
    get  "table_sizes",      to: "queries#table_sizes"
    get  "query_stats",      to: "queries#query_stats"
    get  "unused_indexes",   to: "queries#unused_indexes"
    get  "server_overview",  to: "queries#server_overview"

    # AI features
    post "describe_query",   to: "queries#describe_query"
    post "schema_review",    to: "queries#schema_review"
    post "rewrite_query",    to: "queries#rewrite_query"
    post "index_advisor",    to: "queries#index_advisor"
    post "anomaly_detection", to: "queries#anomaly_detection"
    post "root_cause",       to: "queries#root_cause"
    post "migration_risk",   to: "queries#migration_risk"
    post "variable_review",  to: "queries#variable_review"
    post "connection_advisor", to: "queries#connection_advisor"
    post "workload_digest",  to: "queries#workload_digest"
    post "innodb_health",    to: "queries#innodb_health"
    post "index_planner",    to: "queries#index_planner"
    post "pattern_grouper",  to: "queries#pattern_grouper"
  end

  # Backwards-compat: URLs from 0.8.x (unscoped) redirect into the default
  # database's scope so bookmarks keep working. Drop in 0.10.
  match "*legacy_path", via: :get, to: redirect { |params, req|
    default = MysqlGenius.database_registry.default_key
    if default
      "#{req.script_name}/#{default}/#{params[:legacy_path]}"
    else
      "#{req.script_name}/setup"
    end
  }
end
