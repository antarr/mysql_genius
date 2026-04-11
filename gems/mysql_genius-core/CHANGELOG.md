# Changelog

## 0.4.0

First published release of `mysql_genius-core`. This gem is the Rails-free foundation library for `mysql_genius` and will be the shared core for the forthcoming `mysql_genius-desktop` standalone app. From 0.4.0 onward, `mysql_genius-core` and `mysql_genius` release in lockstep under matching version numbers.

### Added
- `MysqlGenius::Core::Connection` — connection contract with `ActiveRecordAdapter` (used by the Rails engine) and `FakeAdapter` (used in specs).
- `MysqlGenius::Core::SqlValidator` — SELECT-only validation, blocked-table enforcement, row-limit application.
- `MysqlGenius::Core::Ai::{Client, Suggestion, Optimization}` — AI service layer taking an explicit `Core::Ai::Config` instead of reading global configuration.
- `MysqlGenius::Core::Result`, `ColumnDefinition`, `IndexDefinition`, `ServerInfo` — value objects returned by adapters and analyses.
- `MysqlGenius::Core::Analysis::TableSizes` — queries `information_schema.tables` + per-table `COUNT(*)` with size/row/fragmentation metadata.
- `MysqlGenius::Core::Analysis::DuplicateIndexes` — detects left-prefix covering across indexes per table.
- `MysqlGenius::Core::Analysis::QueryStats` — reads `performance_schema.events_statements_summary_by_digest` with sort + limit.
- `MysqlGenius::Core::Analysis::UnusedIndexes` — reads `performance_schema.table_io_waits_summary_by_index_usage` JOINed with `information_schema.tables`.
- `MysqlGenius::Core::Analysis::ServerOverview` — reads `SHOW GLOBAL STATUS` / `SHOW GLOBAL VARIABLES` / `SELECT VERSION()`, computes derived metrics.
- `MysqlGenius::Core::ExecutionResult` — immutable value object for `QueryRunner`'s return.
- `MysqlGenius::Core::QueryRunner` + `QueryRunner::Config` — owns validation, row-limit/timeout-hint application, execution, column masking. Returns `ExecutionResult` or raises `Rejected` / `Timeout`.
- `MysqlGenius::Core::QueryExplainer` — owns EXPLAIN with optional validation-skipping. Returns `Core::Result` or raises `Rejected` / `Truncated`.

MariaDB vs MySQL is detected at runtime so timeout hints use the correct syntax (`SET STATEMENT max_statement_time` vs `MAX_EXECUTION_TIME` optimizer hint).
