# Changelog

## Unreleased

### Changed
- **Internal refactor: extracted Rails-free core library into a new `mysql_genius-core` gem.** The validator, AI services, and value objects now live in `mysql_genius-core`; the `mysql_genius` Rails engine delegates through a new `Core::Connection::ActiveRecordAdapter`. Public API, routes, config DSL, and JSON response shapes are unchanged — host apps see no difference after `bundle update`. See [the design spec](docs/superpowers/specs/2026-04-10-desktop-app-design.md) for the motivation: the new core gem is the foundation for a forthcoming `mysql_genius-desktop` standalone app.
- `mysql_genius` now declares a runtime dependency on `mysql_genius-core ~> 0.1.0.pre`. This dependency resolves transitively; host apps do not need to add it to their Gemfile when using a published release of `mysql_genius`.
- `MysqlGenius::SqlValidator` moved to `MysqlGenius::Core::SqlValidator`.
- `MysqlGenius::AiClient`, `MysqlGenius::AiSuggestionService`, `MysqlGenius::AiOptimizationService` moved to `MysqlGenius::Core::Ai::{Client, Suggestion, Optimization}` and now take an explicit `Core::Ai::Config` instead of reading `MysqlGenius.configuration` at construction time.
- All five database-analysis operations (`TableSizes`, `DuplicateIndexes`, `QueryStats`, `UnusedIndexes`, `ServerOverview`) extracted from the `DatabaseAnalysis` concern into `MysqlGenius::Core::Analysis::*` classes. The `DatabaseAnalysis` concern is now fully delegated; its five actions shrunk from ~295 lines of inline SQL and transformations to 47 lines of thin wrappers. JSON response shapes are unchanged.

### Documentation
- Added README troubleshooting section covering `SSL_connect ... EC lib` / `unable to decode issuer public key` errors that hit Ruby 2.7 + OpenSSL 1.1.x users talking to Google Trust Services-backed hosts like Ollama Cloud. Recommends local Ollama (`http://localhost:11434`) as the fastest unblock, `SSL_CERT_FILE` pointing at a fresher CA bundle as an intermediate fix, and upgrading to Ruby 3.2+ as the durable fix.

### Developer note
- **Dev-time install with this branch requires two path deps.** Until `mysql_genius-core 0.1.0` is published to rubygems (planned for Phase 1b), host apps doing local development against this repo's source need both `gem "mysql_genius", path: "..."` AND `gem "mysql_genius-core", path: "gems/mysql_genius-core"` in their Gemfile. This is transient and goes away with the next published release.

## 0.3.2

### Fixed
- **Query Stats tab stuck on loading spinner** -- commented-out HTML controls in `_tab_query_stats.html.erb` left corresponding JavaScript (`el('qstats-sort').value` and two `addEventListener` calls) throwing `TypeError` on null elements, killing `loadQueryStats` before it could issue its fetch. The commented-out markup and the dead JavaScript have both been removed; client-side sortable column headers continue to provide sort UX.

## 0.3.1

### Added
- **Sortable columns** -- click any column header to sort ascending/descending on all data tables
- **Automated RubyGems publishing** -- GitHub Actions workflow publishes gem on tag push

### Fixed
- **Query stats noise** -- MySQLGenius internal queries (information_schema, performance_schema, SHOW, etc.) are now excluded from the Query Stats tab

## 0.3.0

### Improved
- **SQL syntax highlighting** -- SQL code blocks in tables now feature a dark-themed syntax highlighter with distinct colors for keywords, functions, strings, numbers, operators, identifiers, and placeholders (Catppuccin Mocha palette)
- **Table visual hierarchy** -- redesigned table headers (uppercase, thicker bottom border, rounded top corners), improved row hover states (blue tint), cleaner alternating row colors, removed vertical cell borders
- **Numeric column formatting** -- right-aligned with monospace tabular-nums font for easy scanning; duration values color-coded green/amber/red by severity
- **Overall dashboard polish** -- more generous cell padding, improved inline `code` tag styling, added `mg-badge-success` variant
- **Tab persistence** -- active tab is remembered across page reloads via URL hash

### Fixed
- **Unused indexes SQL error on MySQL 8.0+** -- `reads` and `writes` are reserved words and now use backtick quoting

### Added
- **Dark theme** -- auto-detects system preference, manual toggle via sun/moon button, persisted in localStorage
- **Tables tab** -- renamed from "Table Sizes", now shows engine, collation, auto-increment, last updated, and accurate row counts via `COUNT(*)`
- **Optimize suggestions** -- tables with >10% fragmentation are flagged with an optimize badge

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
