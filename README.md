# MySQLGenius

An AI-powered MySQL dashboard for Rails to help you optimize your database for maximum performance, inspired by [PgHero](https://github.com/ankane/pghero).

## Screenshots

### Dashboard

At-a-glance server health, top slow queries, most expensive queries, and index alerts.

![Dashboard](docs/screenshots/dashboard.png)

### Query Stats

Top queries from `performance_schema` sorted by total time, with SQL syntax highlighting and color-coded durations.

![Query Stats](docs/screenshots/query_stats.png)

### Server Dashboard

Server health: version, connections, InnoDB buffer pool, and query activity with AI-powered diagnostics.

![Server](docs/screenshots/server.png)

### Tables

Row counts, data size, index size, engine, fragmentation, and optimize suggestions for every table.

![Table Sizes](docs/screenshots/table_sizes.png)

### Duplicate Index Detection

Find redundant indexes whose columns are a left-prefix of another index, with ready-to-run `DROP INDEX` statements.

![Duplicate Indexes](docs/screenshots/duplicate_indexes.png)

### Query Explorer

Build queries visually or write raw SQL. Optional AI assistant generates queries from plain English descriptions.

![Query Explorer](docs/screenshots/query_explore.png)

### AI Tools

Schema review, query optimization, index advisor, anomaly detection, root cause analysis, and migration risk assessment.

![AI Tools](docs/screenshots/ai_tools.png)

## Features

- **Dashboard** -- server health, slow queries, expensive queries, index alerts at a glance
- **Query Explorer** -- visual builder + raw SQL editor with AI assistant
- **SQL Syntax Highlighting** -- dark-themed code blocks with color-coded keywords, functions, strings
- **Safe SQL Execution** -- read-only enforcement, blocked tables, masked columns, row limits, timeouts
- **EXPLAIN Analysis** -- run EXPLAIN on any query and view the execution plan
- **9 AI Tools** -- suggestions, optimization, schema review, query rewrite, index advisor, anomaly detection, root cause analysis, migration risk ([details](https://github.com/antarr/mysql_genius/wiki/AI-Features))
- **Slow Query Monitoring** -- captures slow queries via ActiveSupport notifications and Redis ([details](https://github.com/antarr/mysql_genius/wiki/Slow-Query-Monitoring))
- **Index Analysis** -- duplicate index detection, unused index detection with DROP statements
- **Dark Theme** -- auto-detects system preference with manual toggle ([details](https://github.com/antarr/mysql_genius/wiki/Dark-Theme))
- **MariaDB Support** -- automatically detects MariaDB and uses appropriate timeout syntax
- **Self-contained UI** -- no external CSS/JS dependencies, no jQuery, works with any Rails layout

## Quick Start

```ruby
# Gemfile
gem "mysql_genius"
```

```bash
bundle install
rails generate mysql_genius:install
```

Visit `/mysql_genius` in your browser.

For detailed setup, see the [Installation guide](https://github.com/antarr/mysql_genius/wiki/Installation).

## Configuration

```ruby
MysqlGenius.configure do |config|
  config.base_controller = "ApplicationController"
  config.authenticate = ->(controller) { controller.current_user&.admin? }
  config.blocked_tables += %w[oauth_tokens api_keys]
end
```

For full configuration options, see the [Configuration guide](https://github.com/antarr/mysql_genius/wiki/Configuration).

## AI Features (optional)

Works with OpenAI, Azure OpenAI, Ollama Cloud, local Ollama, or any OpenAI-compatible API.

```ruby
MysqlGenius.configure do |config|
  config.ai_endpoint = "https://api.openai.com/v1/chat/completions"
  config.ai_api_key = ENV["OPENAI_API_KEY"]
  config.ai_model = "gpt-4o"
  config.ai_auth_style = :bearer
end
```

For all provider examples, see the [AI Features guide](https://github.com/antarr/mysql_genius/wiki/AI-Features).

### Troubleshooting TLS errors with Ollama Cloud

If you see `SSL_connect ... unable to decode issuer public key` or `SSL_connect ... EC lib` when using an AI feature, your Rails host's Ruby is linked against an older OpenSSL that can't verify modern ECDSA certificate chains (Ollama Cloud is served behind Google Trust Services, whose ECDSA roots trip up OpenSSL 1.1.x and earlier). This is not specific to `mysql_genius` — it affects any Ruby HTTPS call to those hosts.

Three ways to fix it, in order of effort:

**Use a local Ollama instead.** Point the endpoint at `http://localhost:11434/v1/chat/completions`. Your Rails app talks plain HTTP to the local `ollama` binary, which handles the upstream TLS itself using its own modern cert handling. For cloud-backed models, run `ollama signin` once and use the `:cloud` model suffix (e.g., `gemma3:27b-cloud`).

```ruby
MysqlGenius.configure do |config|
  config.ai_endpoint = "http://localhost:11434/v1/chat/completions"
  config.ai_api_key  = "unused-but-required"  # any non-empty string
  config.ai_model    = "gemma3:27b-cloud"     # or any local model
  config.ai_auth_style = :bearer
end
```

**Point Ruby at a fresher CA bundle.** Set `SSL_CERT_FILE` in the environment where Rails boots. On macOS with Homebrew:

```bash
SSL_CERT_FILE=/opt/homebrew/etc/openssl@3/cert.pem bin/rails s
```

This helps if the problem is a stale trust store, but does **not** help if the underlying OpenSSL itself is too old to parse the cert's key algorithm.

**Upgrade Ruby** to 3.2 or newer. Ruby 2.7 is end-of-life (March 2023); newer Rubies link against OpenSSL 3.x which handles modern ECDSA chains correctly. This is the durable fix and the one we recommend for any project still on 2.7.

## Compatibility

| Rails | Ruby |
|-------|------|
| 5.2   | 2.7, 3.0 |
| 6.0   | 2.7, 3.0, 3.1 |
| 6.1   | 2.7, 3.0, 3.1, 3.2, 3.3 |
| 7.0   | 2.7, 3.0, 3.1, 3.2, 3.3 |
| 7.1   | 2.7, 3.0, 3.1, 3.2, 3.3, 3.4 |
| 7.2   | 3.1, 3.2, 3.3, 3.4 |
| 8.0   | 3.2, 3.3, 3.4 |
| 8.1   | 3.2, 3.3, 3.4 |

## Documentation

Full documentation is available on the [Wiki](https://github.com/antarr/mysql_genius/wiki).

## Development

```bash
git clone https://github.com/antarr/mysql_genius.git
cd mysql_genius
bin/setup
bundle exec rspec
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/antarr/mysql_genius.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
