# Changelog

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
