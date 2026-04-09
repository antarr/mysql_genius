# Changelog

## 0.2.0

- **Dashboard-first redesign** -- new default landing page with server health, top slow queries, top expensive queries, and index alert badges
- **Query Explorer** -- merged Visual Builder and SQL Query into one tab with a mode toggle
- **Suggested migrations** -- duplicate and unused index tabs generate timestamped Rails migrations with copy-to-clipboard
- **Install generator** -- `rails generate mysql_genius:install` creates initializer and mounts the engine
- **RuboCop** -- added rubocop-shopify and rubocop-rspec, enforced across the codebase
- **CI matrix** -- added Ruby 3.4, Rails 8.0 and 8.1; excluded incompatible Ruby 3.4 + Rails 6.1/7.0 combos
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
