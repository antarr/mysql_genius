# Multi-Database Support

**Status:** Draft
**Date:** 2026-04-22
**Target version:** 0.9.0 (ships *before* digest-history + regression detector)

## Motivation

Rails apps increasingly run against multiple MySQL connections: primary + analytics, primary + replica, horizontal shards, tenant-per-database. Rails 6+ made this idiomatic with `connects_to` and the multi-db connection handler. mysql_genius currently sees only `ActiveRecord::Base.connection` and gives those apps an incomplete picture.

**Design principle: `config/database.yml` is the single source of truth.** We do not introduce a parallel registry in mysql_genius config. The engine discovers every MySQL connection Rails already knows about for the current environment and surfaces each one in the dashboard. Users don't maintain two configs; what Rails sees, mysql_genius sees.

PgHero (our direct comparable) solved this with its own `databases:` config hash. We deliberately do *not* follow that pattern — it's the wrong shape for apps whose connections are already modeled in Rails' multi-db machinery.

Shipping this *before* 0.9.0's digest-history work means the snapshot table can be correctly keyed on a stable `connection_name` column from day one, rather than migrating it later.

## Goals

1. Multiple MySQL connections visible in the dashboard, switchable via a selector — **auto-discovered from `config/database.yml`**, zero engine config required.
2. Stable URLs: every analysis page scoped by `:database_id`, where the id is the connection name from `database.yml`.
3. Zero-config backwards compatibility: apps on 0.8.x upgrade without touching anything.
4. Per-database keying of all derived state: slow-query Redis keys, stats history, digest snapshots, audit logs.
5. Respect Rails 6+ role-based connections (prefer `:reading` role when a reader is configured so analyses hit replicas, not the writer).
6. Skip non-MySQL adapters cleanly when an app has mixed stores (e.g. a Postgres `cache` connection shouldn't crash the engine).

## Non-goals (v1)

- Cross-database unified views ("top 10 slow queries across ALL dbs"). Each page shows one DB at a time. Add later.
- Non-Rails multi-DB (desktop sidecar already has profiles; spec covers alignment but not parity).
- Server-metrics federation (InnoDB status across shards). Per-DB only.

## Design

### 1. Discovery (no config)

At boot, the engine asks Rails for every configured database in the current environment:

```ruby
ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, include_hidden: false)
```

From that list we build the registry by:

1. **Filter to MySQL adapters only.** We keep configs whose `adapter` is `mysql2`, `trilogy`, or `jdbcmysql`. Everything else is silently skipped.
2. **Pair writers with readers.** Rails convention: a config with `replica: true` (or the older `role:` metadata) is a reader paired with its writer. We group them so the dashboard shows one logical database per writer, with the reader used for analysis queries when present.
3. **Name.** The `database_id` in URLs is the config name from `database.yml` (`primary`, `analytics`, `shard_0`, etc.). If a config name collides with a reserved URL segment (none currently, but plan for `api`), we prefix with an underscore.
4. **Connect lazily.** We do *not* open connections for all discovered databases at boot — a dashboard user may only ever look at one. A database's connection is opened on first request and pooled normally by Rails.

### 2. Opt-in engine config (optional overrides only)

The auto-discovered set is the default. Config exists only for trimming or relabeling:

```ruby
MysqlGenius.configure do |c|
  # All discovered MySQL dbs shown by default. Override only if needed:
  c.databases       = %w[primary analytics]   # allowlist, optional
  c.exclude_databases = %w[cache]             # blocklist, optional
  c.database_labels = { "shard_0" => "US-East Shard" }  # display names
  c.default_database = "primary"              # which tab loads first
end
```

All of these are *optional*. The zero-config path works: if an app has `primary` and `primary_replica` in `database.yml`, the engine shows one "primary" tab and routes analysis queries through the replica.

**Capabilities flag** (`capabilities:` on each entry) is dropped from config — the engine infers it from the connection itself (can it see `performance_schema`? is Redis reachable for slow-query capture?) and hides panels accordingly. This is simpler and more honest than a user-declared capability list.

### 3. Database registry

New class: `MysqlGenius::DatabaseRegistry` (Rails-engine layer, not core).

```ruby
registry = MysqlGenius.database_registry
registry.keys                 # => ["primary", "analytics", "shard_0"]
registry.default_key          # => "primary" (first discovered, or c.default_database)
registry.fetch("analytics")   # => Database struct
registry["analytics"].connection # => Core::Connection::ActiveRecordAdapter
```

Each `Database` entry holds:
- `key` — the config name (`"primary"`)
- `writer_config` / `reader_config` — the raw AR db config hashes
- an internal `AbstractClass` (anonymous `Class.new(ActiveRecord::Base)`) generated at boot with `abstract_class = true` and `connects_to(database: { writing: :primary, reading: :primary_replica })` wired to this database. This gives us a clean `connected_to(role: :reading)` surface without requiring the host app to define its own abstract classes.

`Database#connection` wraps `abstract_class.connected_to(role: :reading)` → `.connection` in a `Core::Connection::ActiveRecordAdapter`. Falls back to `:writing` when no reader is configured. Role handling is centralized in one place.

Legacy `MysqlGenius::Core::Connection::ActiveRecordAdapter` stays unchanged — it still takes a raw AR connection — and the registry is just the new plural-aware entry point.

### 4. URLs and routing

All routes are nested under `:database_id`. Root redirects to the default DB.

```ruby
MysqlGenius::Engine.routes.draw do
  root to: redirect { |_p, req|
    default = MysqlGenius.database_registry.default_key
    "#{req.script_name}/#{default}"
  }

  scope ":database_id", as: :database do
    root to: "queries#index", as: ""

    get  "columns",      to: "queries#columns"
    post "execute",      to: "queries#execute"
    # ... all existing routes nested here
  end
end
```

URL examples:
- Old (0.8.x): `/mysql_genius/slow_queries` → now redirects to `/mysql_genius/primary/slow_queries`.
- New: `/mysql_genius/analytics/slow_queries`.

A compatibility redirect catches any legacy unscoped path and forwards to `primary/<path>` so bookmarks keep working for one minor version. Drop the redirect in 0.10.

### 5. Controller

`ApplicationController` (or whatever the engine base controller is) gains a single before_action:

```ruby
before_action :set_current_database

def set_current_database
  key = params[:database_id] || MysqlGenius.database_registry.default_key
  @database = MysqlGenius.database_registry.fetch(key) or raise ActionController::RoutingError, "Unknown database: #{key}"
end

def current_connection
  @database.connection
end
```

Every controller action that currently calls `ActiveRecord::Base.connection` changes to `current_connection`. That's ~30 callsites — mechanical replace, low risk if we grep carefully.

### 6. Per-database keying of derived state

Three subsystems currently assume one DB and need to be keyed:

**Slow query Redis keys** (`app/controllers/mysql_genius/queries_controller.rb:46`, `lib/mysql_genius/slow_query_monitor.rb`):
- Today: `mysql_genius:slow_queries:<digest>`
- New: `mysql_genius:<database_id>:slow_queries:<digest>`
- Migration: on first write after upgrade, also write the old-style key with a TTL so in-flight dashboards don't go blank. Drop the dual-write in 0.10.

**StatsHistory** (`lib/mysql_genius/engine.rb:18`, `Core::Analysis::StatsHistory`):
- Today: `MysqlGenius.stats_history` is a single instance.
- New: `MysqlGenius.stats_history` becomes a hash-like registry: `stats_history["primary"]` returns that DB's history. The engine's `config.after_initialize` block loops the registry and starts one `StatsCollector` per database.
- Each collector gets a connection provider bound to its database's role-aware connection closure.

**Digest snapshots** (future, per 0.9.0 digest-history spec):
- `connection_name` column (already planned in the digest-history spec) gets populated from `@database.key`. Nothing else changes.

**Audit logger**: add `database_id` to every audit log entry. Back-compat: field is additive.

### 7. UI: database selector

Add a dropdown in the dashboard header:
- Hidden entirely when `registry.keys.size == 1` (vast majority of installs — unchanged UX).
- Shown when multiple databases configured: `<select>` with each database's `label` and `key`, posts `?database_id=X` and follows the current path.

Implementation note: the selector is a partial rendered by the layout. Cheap.

### 8. Capability inference

The existing `capability?(name)` helper in `SharedViewHelpers` (already used by the desktop sidecar to hide Redis-backed features) stays as-is. The registry infers capabilities per database at first-access:

- `performance_schema` reachable? → `:query_stats`, `:slow_queries` available.
- Redis configured? → `:slow_query_log_capture` available.
- `sys` schema present? → `:unused_indexes` available (uses `sys.schema_unused_indexes`).

Unavailable panels are hidden in the UI for that database. No user-declared capability config — we measure, we don't ask.

## Backwards compatibility contract

- Single-DB apps with no config change: **must keep working**. URL `/mysql_genius` redirects to `/mysql_genius/<default>` where `<default>` is the primary MySQL connection Rails already knows about. In practice that's `primary` for almost every app.
- Apps on non-MySQL adapters (e.g. dashboard mounted against Postgres during a migration) get a clear error page instead of cryptic errors.
- Redis slow-query data written before the upgrade remains readable (dual-key write period).
- Audit log shape is additive; existing parsers are unaffected.

## Rollout plan

- **0.9.0-rc1**: registry, config parsing, nested routes, controller before_action, connection plumbing. Compatibility redirect live. UI selector. No per-DB derived-state keying yet — legacy Redis keys and StatsHistory stay global (one DB reads them, others show empty panels).
- **0.9.0-rc2**: per-DB Redis keys (with dual-write), per-DB StatsHistory. Audit log `database_id`.
- **0.9.0**: docs, migration guide ("I have multiple MySQL connections, here's how"), CHANGELOG, blog post.
- **0.10.0**: drop legacy compatibility redirect and legacy Redis key dual-write.

Follow-up features this unblocks:
- Digest-history + regression detector (0.9.1) — `connection_name` column populates correctly from the start.
- Cross-database summary views (0.10).
- Replica lag panel (0.10) — natural fit since readers are already discovered.

## Open questions

1. **How does the default database get chosen?** First MySQL config Rails returns for the environment, OR a `c.default_database = "primary"` override? *Recommendation: first discovered by default, explicit setting overrides.*
2. **Authentication callback signature**: does `c.authenticate` proc need to receive the current database too? Some teams will want to grant dashboard access to only some databases per user. *Recommendation: extend proc to optionally accept a second arg (`(controller)` or `(controller, database)`), detect arity, preserve back-compat.*
3. **Shards**: Rails `connects_to(shards: { ... })` produces multiple configs that share a name but differ by shard key. Do we surface each shard as its own tab, or group them under one tab with a shard selector? *Recommendation: one tab per shard in v1 (simplest), with a follow-up for a unified shard view once we understand the UX.*
4. **Config name collisions**: if the host app's `database.yml` has a key named something like `api` (already a URL segment we might want), we prefix with `_`. Is that surprising? *Recommendation: yes but document it; the alternative is failing to boot, which is worse.*
5. **Ambient `ActiveRecord::Base.connection` switching**: we don't want mysql_genius pages to pollute the thread-local connection of the host app. Using `connected_to { ... }` blocks per request keeps this isolated. Verify no leakage in specs.

## Files touched

- `lib/mysql_genius/configuration.rb` — add `databases`, `exclude_databases`, `database_labels`, `default_database` accessors (all optional)
- `lib/mysql_genius/database_registry.rb` (new) — auto-discovers from `ActiveRecord::Base.configurations`
- `lib/mysql_genius/database.rb` (new) — the per-DB struct that wraps role-aware connection
- `lib/mysql_genius/engine.rb` — iterate registry in `config.after_initialize`; one StatsCollector per DB
- `lib/mysql_genius.rb` — expose `MysqlGenius.database_registry`
- `config/routes.rb` — wrap all routes in `scope ":database_id"`, add root redirect + legacy path redirect
- `app/controllers/mysql_genius/application_controller.rb` (or equivalent) — `set_current_database` before_action, `current_connection` helper
- `app/controllers/mysql_genius/queries_controller.rb` — replace all `ActiveRecord::Base.connection` with `current_connection` (~30 callsites)
- `lib/mysql_genius/slow_query_monitor.rb` — per-DB Redis key scheme, dual-write shim
- `app/views/mysql_genius/queries/_database_selector.html.erb` (new partial)
- `app/views/layouts/mysql_genius/application.html.erb` — render selector
- `spec/` — registry discovery tests (with multi-db fixtures: primary+replica, shards, mixed-adapter, MySQL-only), routing tests (nested + redirect), controller filter tests, capability inference tests, Redis dual-write tests, connection-leak-to-host-app tests
- `docs/guides/multi-database.md` (new)
