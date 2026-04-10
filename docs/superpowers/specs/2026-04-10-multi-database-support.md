# Multi-Database Support

## Summary

Add support for monitoring multiple MySQL/MariaDB databases from a single MySQL Genius dashboard. Databases are auto-detected from Rails' `database.yml` with optional overrides via YAML config files and the Ruby initializer.

## Database Discovery & Connection Resolution

**Auto-detection:** At boot, MySQL Genius reads `ActiveRecord::Base.configurations` and filters to MySQL/MariaDB adapters. Each entry becomes an available database keyed by its spec name (`primary`, `analytics`, etc.).

**Connection resolution:** Uses Rails' connection management rather than managing raw connection pools. No duplicate pool configuration. For Rails 6.1+ (which introduced `ActiveRecord::Base.configurations` as objects), use the configurations API to look up and establish connections. For Rails 5.2–6.0 (which the gem supports), fall back to reading the raw `database.yml` hash and establishing connections via `ActiveRecord::Base.establish_connection`. The connection lookup strategy must be version-aware.

**YAML overrides** can exclude databases, rename display labels, and add per-database settings.

**Single-database backward compat:** If only one MySQL database exists and no YAML file is present, behavior is identical to today — no URL prefix required, no dropdown shown.

## Configuration System

### YAML File Loading

1. `config/mysql_genius.yml` — base config (always loaded if present)
2. `config/mysql_genius.#{Rails.env}.yml` — environment override (deep-merged over base)

### YAML Structure

```yaml
defaults:
  blocked_tables: [sessions, schema_migrations, ar_internal_metadata]
  masked_column_patterns: [password, secret, digest, token]
  max_row_limit: 1000
  default_row_limit: 25
  query_timeout_ms: 30000
  featured_tables: []

databases:
  primary:
    label: "Main App"
  analytics:
    label: "Analytics Warehouse"
    blocked_tables: [raw_events, etl_staging]
    query_timeout_ms: 60000
    max_row_limit: 5000

exclude: [internal_cache_db]
```

### Resolution Order (most specific wins)

1. Ruby initializer per-database override
2. YAML per-database setting
3. Ruby initializer global setting
4. YAML `defaults` setting
5. Hardcoded defaults (current values in `Configuration#initialize`)

### New Classes

**`DatabaseConfig`** — Holds per-database settings. Delegates missing settings to the global config via explicit fallback.

**`Configuration#databases`** — Hash of `DatabaseConfig` objects.

### Initializer Additions

```ruby
MysqlGenius.configure do |config|
  config.database(:analytics) do |db|
    db.blocked_tables = ['raw_events']
  end
end
```

### Initializer Keeps (not in YAML)

`authenticate`, `ai_client`, `ai_endpoint`, `ai_api_key`, `ai_model`, `ai_auth_style`, `ai_system_context`, `base_controller`, `audit_logger`, `redis_url`, `slow_query_threshold_ms`.

### Per-Database YAML Settings

`blocked_tables`, `masked_column_patterns`, `featured_tables`, `default_columns`, `max_row_limit`, `default_row_limit`, `query_timeout_ms`, `label`.

## Routing & URL Structure

### Route Definition

```ruby
MysqlGenius::Engine.routes.draw do
  scope '(:database)', constraints: { database: /[a-z0-9_]+/ } do
    root 'queries#index'
    # ... all existing routes
  end
end
```

### URL Examples

- `/mysql_genius/` — default database (primary), single-db backward compat
- `/mysql_genius/primary/` — explicit primary
- `/mysql_genius/analytics/` — analytics database
- `/mysql_genius/analytics/execute` — AJAX endpoints scoped to database

### Controller Resolution (`before_action` in `BaseController`)

1. If `params[:database]` is present, look it up in configured databases
2. If absent and only one database exists, use it (backward compat)
3. If absent and multiple databases exist, redirect to the first one
4. If database name is invalid, return 404

### Connection Switching

```ruby
def resolve_database!
  @current_database = MysqlGenius.databases[params[:database] || default_key]
end
```

## Internal Connection Helper & Migration Path

### Core Change

All 25+ `ActiveRecord::Base.connection` call sites get replaced with a `connection` helper method on `BaseController`.

### BaseController Gains

```ruby
def current_database_config
  @current_database_config  # set by resolve_database!
end

def connection
  @current_connection  # set during connection resolution
end
```

### Concern Updates

All concerns (`QueryExecution`, `DatabaseAnalysis`, `AiFeatures`) currently do `connection = ActiveRecord::Base.connection` at the top of each method. These change to use the controller's `connection` helper.

### Service Updates

`AiSuggestionService` and `AiOptimizationService` accept a `connection` parameter:

```ruby
# Before
AiSuggestionService.new.call(prompt, queryable_tables)

# After
AiSuggestionService.new.call(prompt, queryable_tables, connection: connection)
```

### `queryable_tables` Update

Uses the resolved connection and per-database `blocked_tables` config.

## UI — Database Switcher

**Header dropdown:** When multiple databases are configured, a dropdown in the dashboard header shows the current database label. Clicking an option navigates to that database's URL path (full page load).

**Single database:** No dropdown rendered. Identical to current UI.

**JavaScript path awareness:**

```html
<body data-base-path="<%= mysql_genius.root_path(database: @current_database_key) %>">
```

All fetch calls use `document.body.dataset.basePath` as the URL prefix instead of hardcoded paths.

**Tab state:** When switching databases, tab data resets. The active tab is preserved via URL parameter.

**Database indicator:** Current database label always visible in the header.

## Testing Strategy

### Unit Tests

- `DatabaseConfig` — merging/fallback logic, per-database overrides resolve correctly
- `Configuration` — YAML loading, environment file merging, `databases` hash population, exclude list
- `DatabaseRegistry` (auto-detection module) — discovers MySQL adapters from AR configurations, ignores non-MySQL, respects exclude list
- Existing service specs updated to accept `connection` parameter

### Controller/Request Tests

- Routing: `/:database/execute` resolves, invalid database returns 404, missing database with single DB works, missing with multi-DB redirects
- Connection scoping: verify resolved connection matches requested database (mocked)

### Backward Compatibility Tests

- No YAML file + single database = current behavior, no URL prefix
- Existing initializer-only config still works

No integration tests against real multi-DB — the engine tests verify wiring with stubbed connections.
