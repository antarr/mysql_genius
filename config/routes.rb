MysqlGenius::Engine.routes.draw do
  root to: "queries#index"

  get  "columns",      to: "queries#columns"
  post "execute",      to: "queries#execute"
  post "explain",      to: "queries#explain"
  post "suggest",      to: "queries#suggest"
  post "optimize",     to: "queries#optimize"
  get  "slow_queries",      to: "queries#slow_queries"
  get  "duplicate_indexes", to: "queries#duplicate_indexes"
  get  "table_sizes",      to: "queries#table_sizes"
end
