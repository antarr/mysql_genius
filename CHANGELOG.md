# Changelog

## Unreleased

### Added
- **Multi-database support** -- monitor multiple MySQL/MariaDB databases from a single dashboard
- **Auto-detection** -- MySQL databases are discovered from Rails `database.yml` at boot (supports Rails 5.2 through 8.1)
- **YAML configuration** -- per-database settings via `config/mysql_genius.yml` with environment-specific overrides (`config/mysql_genius.production.yml`)
- **Per-database settings** -- `blocked_tables`, `masked_column_patterns`, `featured_tables`, `default_columns`, `max_row_limit`, `default_row_limit`, `query_timeout_ms` can be configured per database, falling back to global defaults
- **Database switcher** -- dropdown in the dashboard header to switch between databases (hidden in single-database setups)
- **URL-scoped routing** -- `/mysql_genius/analytics/`, `/mysql_genius/primary/execute`, etc. Optional prefix -- existing URLs continue to work
- **`config.database(:name)` DSL** -- per-database overrides in the Ruby initializer
- **Install generator** -- now also copies `config/mysql_genius.yml` template

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
