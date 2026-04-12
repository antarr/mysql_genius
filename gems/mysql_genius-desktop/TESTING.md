# Manual end-to-end testing

This recipe boots a local MySQL in Docker, writes a config file, runs the sidecar, and curls every registered endpoint. Use it to verify the sidecar works end-to-end against a real database before merging.

## 1. Start MySQL

```bash
docker run --rm --name mysql-genius-test \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=app_test \
  -e MYSQL_USER=readonly \
  -e MYSQL_PASSWORD=readonly \
  -p 3307:3306 \
  -d mysql:8.0
```

Wait 10 seconds for MySQL to finish initializing, then seed a tiny schema:

```bash
docker exec -i mysql-genius-test mysql -u root -proot app_test <<'SQL'
CREATE TABLE users (
  id bigint AUTO_INCREMENT PRIMARY KEY,
  email varchar(255) NOT NULL,
  password_hash varchar(255) NOT NULL,
  created_at datetime DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_email (email)
);
CREATE TABLE orders (
  id bigint AUTO_INCREMENT PRIMARY KEY,
  user_id bigint NOT NULL,
  total_cents int NOT NULL,
  created_at datetime DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_user_id (user_id)
);
INSERT INTO users (email, password_hash) VALUES
  ('alice@example.com', 'x'), ('bob@example.com', 'y');
INSERT INTO orders (user_id, total_cents) VALUES (1, 1000), (1, 2500), (2, 500);
GRANT SELECT ON app_test.* TO 'readonly'@'%';
FLUSH PRIVILEGES;
SQL
```

## 2. Write a config file

Create `~/.mysql_genius.yml`:

```yaml
version: 1
mysql:
  host: 127.0.0.1
  port: 3307
  username: readonly
  password: readonly
  database: app_test
server:
  port: 4567
  bind: 127.0.0.1
security:
  masked_column_patterns:
    - password
query:
  default_row_limit: 100
  timeout_seconds: 5
```

## 3. Run the sidecar

```bash
cd gems/mysql_genius-desktop
bundle exec exe/mysql-genius-sidecar
```

Expected: `mysql-genius-sidecar starting on http://127.0.0.1:4567/` on stderr; Puma banner.

## 4. Curl the endpoints

```bash
curl -s http://127.0.0.1:4567/ | grep -c 'data-tab='                       # >= 8 (tabs rendered)
curl -s http://127.0.0.1:4567/columns?table=users | jq .                   # [id, email, created_at] (password_hash masked out)
curl -s -X POST http://127.0.0.1:4567/execute \
  -d 'sql=SELECT id, email FROM users' | jq .                              # { columns: [...], rows: [...], row_count: 2, ... }
curl -s -X POST http://127.0.0.1:4567/explain \
  -d 'sql=SELECT id FROM users WHERE email = "alice@example.com"' | jq .
curl -s http://127.0.0.1:4567/duplicate_indexes | jq .
curl -s http://127.0.0.1:4567/table_sizes | jq .
curl -s http://127.0.0.1:4567/query_stats | jq .
curl -s http://127.0.0.1:4567/unused_indexes | jq .
curl -s http://127.0.0.1:4567/server_overview | jq .
```

## 5. Browser smoke test

Open <http://127.0.0.1:4567/> in a browser and click through every tab:

- [x] Dashboard — server stats card populated, Query Stats table populated, Duplicate/Unused index counts shown
- [ ] Slow Queries — tab button should NOT be present
- [x] Query Stats — table populated (requires performance_schema)
- [x] Server — stats visible, Root Cause / Anomaly buttons NOT visible
- [x] Tables — lists `users`, `orders`
- [x] Unused Indexes — loads without error
- [x] Duplicate Indexes — loads without error
- [x] Query Explorer — can run `SELECT 1`, EXPLAIN a query, see results
- [ ] AI Tools — tab button hidden (AI not configured in this test)

## 6. Verify unregistered routes are 404

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4567/slow_queries          # 404
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:4567/anomaly_detection  # 404
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:4567/root_cause    # 404
```

## 7. Stop and clean up

```bash
# Ctrl-C the sidecar process.
docker stop mysql-genius-test
rm -f ~/.mysql_genius.yml
```

## Troubleshooting

- **"Failed to connect to MySQL at 127.0.0.1:3307"** — wait longer after `docker run`; MySQL needs 5-15s to initialize.
- **"Query statistics require performance_schema to be enabled"** — MySQL 8.0 enables performance_schema by default; older MySQL / MariaDB may need `performance_schema=ON` in my.cnf.
- **"Access denied"** — double-check the `GRANT SELECT` ran against the right user/host.
