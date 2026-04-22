# Running integration tests

Our default `bundle exec rspec` runs fast, offline unit specs with stubbed
connections. The **integration suite** (`spec/integration/`) talks to a
real MySQL server, imports the Sakila fixture, and asserts that our
analysis classes produce correct output against real `performance_schema`
rows. It's gated by `REAL_MYSQL=1` so you only pay the setup cost when
you actually need it.

## Quick start: Docker

If you have Docker, the fastest path is a one-liner MySQL container:

```bash
# Start MySQL (pick the version you want to test against):
docker run -d --name mg-mysql \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=mysql_genius_test \
  -p 3306:3306 \
  mysql:8.4

# Wait a few seconds for it to initialize, then:
REAL_MYSQL=1 \
DATABASE_URL=mysql2://root:root@127.0.0.1:3306/mysql_genius_test \
BUNDLE_WITH=integration \
bundle exec rspec spec/integration
```

Stop it when you're done:

```bash
docker stop mg-mysql && docker rm mg-mysql
```

### Other MySQL versions / MariaDB

Swap the image tag:

```bash
docker run -d --name mg-mysql ... mysql:8.0          # previous LTS
docker run -d --name mg-mysql ... mysql:5.7          # EOL but still common in prod
docker run -d --name mg-mysql ... mariadb:11         # MariaDB support
```

CI runs all four against both `mysql2` and `trilogy` adapters — see
`.github/workflows/ci.yml`'s `integration` matrix.

## Quick start: Homebrew (Mac, no Docker)

```bash
brew install mysql
brew services start mysql

# First-time setup — create the app DB and set the root password:
mysql -uroot -e "
  ALTER USER 'root'@'localhost' IDENTIFIED BY 'root';
  CREATE DATABASE mysql_genius_test;
"

REAL_MYSQL=1 \
DATABASE_URL=mysql2://root:root@127.0.0.1:3306/mysql_genius_test \
BUNDLE_WITH=integration \
bundle exec rspec spec/integration
```

## What happens on the first run

1. `SakilaFixture.load!` imports the Sakila schema and data from
   `spec/fixtures/sakila/` via the `mysql` CLI. Creates a `sakila` schema
   alongside `mysql_genius_test` — they stay isolated.
2. `WorkloadGenerator.run!` issues ~360 SELECTs against Sakila to
   populate `performance_schema.events_statements_summary_by_digest` and
   `events_statements_history_long` with realistic variety.
3. Spec examples run against the seeded state.

Subsequent runs skip step 1 (the loader is idempotent — it checks
`sakila.film` row count). Force a reload with `SAKILA_RELOAD=1`.

## Running a single spec

Examples only run when `REAL_MYSQL=1` is set:

```bash
REAL_MYSQL=1 DATABASE_URL=... BUNDLE_WITH=integration \
  bundle exec rspec spec/integration/query_stats_integration_spec.rb
```

## Troubleshooting

**`sakila_fixture: mysql CLI not found on PATH`**

The loader shells out to `mysql` to import the SQL dump (which uses
DELIMITER / trigger syntax that ActiveRecord can't handle on its own).
On Mac, `brew install mysql-client` and follow the `brew info
mysql-client` instructions to put it on your PATH. On Linux, your
distro's `mysql-client` package.

**`Access denied for user 'root'@'localhost'`**

The Docker image sets the password to whatever `MYSQL_ROOT_PASSWORD`
was at first run — changing it later doesn't retroactively update the
existing volume. Easiest fix: `docker rm -v mg-mysql` and start fresh.

**`Table 'sakila.film' doesn't exist` on a rerun**

Something interrupted the first load. Force a reload:

```bash
SAKILA_RELOAD=1 REAL_MYSQL=1 ... bundle exec rspec spec/integration
```

**Tests pass locally but fail on CI (or vice versa)**

The MySQL version matters — see the CI matrix. To reproduce a CI-only
failure, start the same image (`docker run ... mysql:5.7`) and rerun
locally. Version-specific quirks are usually `performance_schema` column
presence (see the 0.8.1 DIGEST fix in the CHANGELOG for an example).
