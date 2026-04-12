# mysql_genius-desktop

Terminal-launched Sinatra sidecar that serves the [MysqlGenius](https://github.com/antarr/mysql_genius) dashboard against an arbitrary MySQL/MariaDB server.

**Status:** Unreleased. This gem lives in the `mysql_genius` monorepo and is not published to RubyGems. Use it via a path dependency.

## Usage

1. Add to your Gemfile:

   ```ruby
   gem "mysql_genius-desktop", path: "/path/to/mysql_genius/gems/mysql_genius-desktop"
   ```

2. Write a config file (see `TESTING.md` for a template):

   ```yaml
   version: 1
   mysql:
     host: localhost
     username: readonly
     database: app_production
   ```

3. Run the sidecar:

   ```bash
   bundle exec mysql-genius-sidecar --config ./mg.yml
   ```

4. Open `http://127.0.0.1:4567/` in a browser.

## Running the specs

```bash
bundle install
bundle exec rspec
```

## Scope

- MVP: one YAML-configured connection, stateless dashboard.
- Not supported yet: Connection Manager UI, profile JSON storage, session-token auth, Redis-backed slow query / anomaly / root cause features, Tauri shell.

See `docs/superpowers/specs/2026-04-12-phase-2b-desktop-sidecar-design.md` in the monorepo for the full design.
