# Getting Started with MysqlGenius (Rails)

## Installation

Add to your Gemfile:

```ruby
gem "mysql_genius"
```

```bash
bundle install
```

## Mount the engine

In `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount MysqlGenius::Engine, at: "/mysql_genius"
  # ... your other routes
end
```

## Configuration

Create an initializer at `config/initializers/mysql_genius.rb`:

```ruby
MysqlGenius.configure do |config|
  # Authentication (required in production)
  config.authenticate = ->(controller) {
    # Example: restrict to admin users
    controller.current_user&.admin?
  }

  # Tables to hide from the dashboard
  config.blocked_tables = %w[
    schema_migrations
    ar_internal_metadata
  ]

  # Columns to mask in query results
  config.masked_column_patterns = %w[
    password
    token
    secret
    ssn
  ]

  # Query limits
  config.default_row_limit = 100
  config.max_row_limit = 10_000
  config.query_timeout_ms = 10_000

  # AI features (optional)
  config.ai_endpoint = ENV["MYSQL_GENIUS_AI_ENDPOINT"]
  config.ai_api_key = ENV["MYSQL_GENIUS_AI_KEY"]
  config.ai_model = "gpt-4o-mini"
  config.ai_auth_style = :bearer

  # Stats collection (background thread, default: true)
  config.stats_collection = true

  # Slow query monitoring via Redis (optional)
  # config.redis_url = ENV["REDIS_URL"]
end
```

## Visit the dashboard

Start your Rails server and navigate to:

```
http://localhost:3000/mysql_genius
```

## Features

### Dashboard
Overview of server health, top slow queries, expensive queries, duplicate/unused index counts.

### Query Explorer
Run SELECT queries against your database with syntax highlighting, EXPLAIN output, and AI-powered suggestions.

### Query Stats
Top queries from `performance_schema.events_statements_summary_by_digest`. Click any query to see a detail page with time-series performance charts.

### Server
Server status, connections, InnoDB buffer pool, query activity.

### Tables
Table sizes with fragmentation detection. Tables needing optimization get an "AI Optimize" button.

### Indexes
Duplicate and unused index detection.

### AI Tools (when configured)
- **Schema Review** — find anti-patterns in your schema
- **Migration Risk** — assess DDL safety before deploying
- **Query Description** — explain what a query does in plain English
- **Query Rewrite** — suggest optimized versions of slow queries
- **Index Advisor** — recommend indexes for specific queries

## Security

**Always configure authentication in production.** Without it, anyone who can reach the mounted path can view your database schema and run SELECT queries.

The `blocked_tables` and `masked_column_patterns` settings provide defense-in-depth but are not a substitute for authentication.

## Supported databases

- MySQL 5.7+
- MySQL 8.0+
- MariaDB 10.3+

Some features (query stats, unused indexes) require `performance_schema` to be enabled.
