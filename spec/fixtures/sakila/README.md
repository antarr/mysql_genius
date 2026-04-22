# Sakila Sample Database (fixture)

Sakila is Oracle's canonical sample MySQL database — DVD rental store
domain: films, actors, customers, rentals, payments, inventory, stores.
It's used by our integration test suite as a realistic dataset for
exercising analyses (query_stats, unused_indexes, EXPLAIN, slow_queries,
etc.) against a real MySQL server.

- **Version**: 1.5
- **Source**: https://downloads.mysql.com/docs/sakila-db.tar.gz
- **Downloaded**: 2026-04-22
- **License**: BSD — see `LICENSE` in this directory.
- **Rows**: ~47k total across 16 tables. Small enough to load in <1s on CI.

## Layout

```
schema.sql      DDL from upstream (unchanged). Creates the `sakila`
                schema — intentionally isolated from the app's test DB so
                integration specs can treat it as a second database.
data.sql.gz     Bulk INSERTs, gzipped (~660KB vs 3.4MB raw) to stay below
                GitHub's 1MB diff-preview threshold. Gunzip before loading.
LICENSE         BSD license text, preserved verbatim per Sakila's
                redistribution terms.
```

## Regenerating

If a new Sakila release drops (rare — Sakila's 1.5 has been stable since
2006), regenerate with:

```bash
cd spec/fixtures/sakila
curl -sSfL -o /tmp/sakila-db.tar.gz https://downloads.mysql.com/docs/sakila-db.tar.gz
tar -xzf /tmp/sakila-db.tar.gz --strip-components=1 \
  sakila-db/sakila-schema.sql sakila-db/sakila-data.sql
mv sakila-schema.sql schema.sql
gzip -9 sakila-data.sql
mv sakila-data.sql.gz data.sql.gz
rm /tmp/sakila-db.tar.gz
```

Then verify the integration suite still passes:

```bash
REAL_MYSQL=1 bundle exec rspec spec/integration
```

## Usage

See `spec/support/sakila_fixture.rb` for the loader that imports this
fixture into a test MySQL server, and `spec/support/workload_generator.rb`
for the pre-baked query mix that exercises it.
