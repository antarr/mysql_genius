# Changelog

## Unreleased

- **Optional database prefix in routes** -- all routes are now wrapped in `scope "(:database)"` so `/mysql_genius/` continues to work (backward compatible) and `/mysql_genius/analytics/` routes to a named database
- **DatabaseConfig class** -- foundational per-database configuration object that holds overridable settings (`blocked_tables`, `masked_column_patterns`, `featured_tables`, `default_columns`, `max_row_limit`, `default_row_limit`, `query_timeout_ms`) and falls back to the global `Configuration` for any unset value
- **Configuration#database DSL** -- `config.database(:name) { |db| ... }` block lets users configure per-database overrides inside `MysqlGenius.configure`; repeated calls to the same key merge into the same `DatabaseConfig` instance
- **DatabaseRegistry** -- `MysqlGenius::DatabaseRegistry` module handles YAML config loading (`config/mysql_genius.yml` + environment overrides), auto-detection of MySQL databases from `ActiveRecord::Base.configurations`, and helper methods (`multi_db?`, `default_key`, `deep_merge`); the `build!` method is the single entry point called at engine boot
- **BaseController database resolution** -- `resolve_database!` before-action resolves the active database from params, redirects to a default in multi-db mode when none is specified, and returns 404 for unknown databases; adds `connection`, `current_database_key`, `current_database_config`, `multi_db?`, and `available_databases` helpers (view-accessible via `helper_method`)
- **QueriesController multi-db wiring** -- `index` now exposes `@multi_db`, `@current_database_key`, and `@available_databases` to the view; `columns` and `queryable_tables` use the `connection` helper and `current_database_config` instead of `ActiveRecord::Base.connection` and the global config

## 0.2.0

- **Dashboard-first redesign** -- new default landing page with server health, top slow queries, top expensive queries, and index alert badges
- **Query Explorer** -- merged Visual Builder and SQL Query into one tab with a mode toggle
- **Suggested migrations** -- duplicate and unused index tabs generate timestamped Rails migrations with copy-to-clipboard
- **Install generator** -- `rails generate mysql_genius:install` creates initializer and mounts the engine
- **RuboCop** -- added rubocop-shopify and rubocop-rspec, enforced across the codebase
- **CI matrix** -- added Ruby 3.4, Rails 8.0 and 8.1; excluded incompatible Ruby 3.4 + Rails 6.1/7.0 combos
- **Smarter AI prompts** -- schema review now includes primary keys and Rails-aware context (no foreign key constraint recommendations, recommends indexes on FK columns instead)
- **SSL fix** -- explicit CA certificate file for AI API requests
- Tab reorder: Dashboard, Slow Queries, Query Stats, Server, Table Sizes, Unused Indexes, Duplicate Indexes, Query Explorer, AI Tools
- Dashboard links to Server tab for full details
- Clipboard fallback for non-HTTPS environments
- Gemspec description updated to lead with monitoring features

## 0.1.0

- Initial release
- Visual query builder with column selection, filters, and ordering
- Safe SQL execution (read-only, blocked tables, masked columns, row limits, timeouts)
- EXPLAIN analysis
- AI-powered query suggestions (optional)
- AI-powered query optimization from EXPLAIN output (optional)
- Slow query monitoring via Redis
- Audit logging
- MariaDB support
