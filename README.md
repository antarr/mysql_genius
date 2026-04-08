# MysqlGenius

A MySQL performance dashboard and query explorer for Rails. Like [PgHero](https://github.com/ankane/pghero), but for MySQL -- with AI-powered query suggestions and optimization.

## Features

- **Visual Query Builder** -- point-and-click query construction with column selection, filters, and ordering
- **Safe SQL Execution** -- read-only enforcement, blocked tables, masked sensitive columns, row limits, query timeouts
- **EXPLAIN Analysis** -- run EXPLAIN on any query and view the execution plan
- **AI Query Suggestions** -- describe what you want in plain English, get SQL back (optional)
- **AI Query Optimization** -- get actionable optimization suggestions from EXPLAIN output (optional)
- **Slow Query Monitoring** -- captures slow SELECT queries via ActiveSupport notifications and Redis
- **Audit Logging** -- logs all query executions, rejections, and errors
- **MariaDB Support** -- automatically detects MariaDB and uses appropriate timeout syntax

## Requirements

- Rails 5.2+
- MySQL or MariaDB
- Redis (optional, for slow query monitoring)

## Installation

Add to your Gemfile:

```ruby
gem "mysql_genius"
```

Then run:

```
bundle install
```

## Setup

### 1. Mount the engine

In `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount MysqlGenius::Engine, at: "/mysql_genius"
end
```

### 2. Configure

Create `config/initializers/mysql_genius.rb`:

```ruby
MysqlGenius.configure do |config|
  # Authentication -- restrict who can access the dashboard
  config.authenticate = ->(controller) {
    controller.current_user&.admin?
  }

  # Tables to feature at the top of the visual builder dropdown (optional)
  config.featured_tables = %w[users posts comments]

  # Tables to block entirely (defaults include sessions, schema_migrations, ar_internal_metadata)
  config.blocked_tables += %w[oauth_tokens api_keys]

  # Column patterns to redact in query results
  config.masked_column_patterns = %w[password secret digest token ssn]

  # Default columns checked in the visual builder per table (optional)
  config.default_columns = {
    "users" => %w[id name email created_at],
    "posts" => %w[id title user_id published_at]
  }

  # Query limits
  config.max_row_limit = 1000
  config.default_row_limit = 25
  config.query_timeout_ms = 30_000

  # Slow query monitoring (requires Redis)
  config.redis_url = ENV["REDIS_URL"]
  config.slow_query_threshold_ms = 250

  # Audit logging
  config.audit_logger = Logger.new(Rails.root.join("log", "mysql_genius.log"))
end
```

### 3. AI Features (optional)

MysqlGenius supports AI-powered query suggestions and optimization. Configure an OpenAI-compatible API:

```ruby
MysqlGenius.configure do |config|
  # Option A: Direct API endpoint (Azure OpenAI, OpenAI, etc.)
  config.ai_endpoint = ENV["OPENAI_ENDPOINT"]
  config.ai_api_key = ENV["OPENAI_API_KEY"]

  # Option B: Custom client (any callable that returns OpenAI-compatible responses)
  # config.ai_client = ->(messages:, temperature:) {
  #   MyAiService.chat(messages, temperature: temperature)
  # }

  # Add domain context for better AI suggestions
  config.ai_system_context = <<~CONTEXT
    This is an e-commerce database.
    - `users` stores customer accounts. Primary key is `id`.
    - `orders` tracks purchases. Linked to users via `user_id`.
    - `products` contains the product catalog.
    - Soft-deleted records have `deleted_at IS NOT NULL`.
  CONTEXT
end
```

When AI is not configured, the AI Assistant panel and optimization buttons are hidden automatically.

## Usage

Visit `/mysql_genius` in your browser. The dashboard has three tabs:

1. **Visual Builder** -- select a table, pick columns, add filters, and run queries without writing SQL
2. **SQL Query** -- write raw SQL with the AI assistant available for help
3. **Slow Queries** -- view captured slow queries with options to EXPLAIN or edit them

## Compatibility

Tested against:

| Rails | Ruby |
|-------|------|
| 5.2   | 2.7, 3.0 |
| 6.0   | 2.7, 3.0, 3.1 |
| 6.1   | 2.7, 3.0, 3.1, 3.2, 3.3 |
| 7.0   | 2.7, 3.0, 3.1, 3.2, 3.3 |
| 7.1   | 2.7, 3.0, 3.1, 3.2, 3.3 |
| 7.2   | 3.1, 3.2, 3.3 |

## Development

```
git clone https://github.com/antarr/mysql_genius.git
cd mysql_genius
bin/setup
bundle exec rspec
```

To test against a specific Rails version:

```
RAILS_VERSION=6.1 bundle update && bundle exec rspec
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/antarr/mysql_genius.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
