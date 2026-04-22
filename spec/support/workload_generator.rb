# frozen_string_literal: true

# Runs a curated mix of queries against the Sakila fixture to populate
# `performance_schema.events_statements_summary_by_digest` and
# `events_statements_history_long` with realistic variety — indexed
# lookups, full table scans, joins, aggregates, sorts, subqueries,
# mixed with a few deliberately slow shapes.
#
# Called once per integration test run (typically from a before(:suite)
# hook) after SakilaFixture.load! so the analysis specs have real
# digest stats to inspect.
#
# Queries run in-order, fixed iteration count — deterministic. Specs that
# need a particular query shape can reference the QUERIES constant
# directly.
module WorkloadGenerator
  # Each entry is a [name, sql] pair. Names are free-form; they're only
  # used in error messages if a query fails. The SQL targets the sakila
  # schema explicitly so this works regardless of the connection's
  # current database.
  QUERIES = [
    # Indexed PK lookup — fast, lots of digest calls
    [:indexed_pk,       "SELECT * FROM sakila.customer WHERE customer_id = 42"],
    # Indexed FK lookup
    [:indexed_fk,       "SELECT * FROM sakila.rental WHERE customer_id = 1"],
    # Full-scan with LOWER() disabling index use
    [:full_scan,        "SELECT * FROM sakila.customer WHERE LOWER(email) LIKE '%@sakilacustomer.org'"],
    # Join across two tables (customer + rental)
    [:join_2way,        "SELECT c.first_name, r.rental_date FROM sakila.customer c JOIN sakila.rental r USING (customer_id) LIMIT 100"],
    # Aggregate with GROUP BY
    [:group_by,         "SELECT rating, COUNT(*) FROM sakila.film GROUP BY rating"],
    # Sort without an index (filesort)
    [:filesort,         "SELECT * FROM sakila.film ORDER BY length DESC LIMIT 20"],
    # Correlated subquery
    [:subquery,         "SELECT title FROM sakila.film WHERE film_id IN (SELECT film_id FROM sakila.inventory WHERE store_id = 1)"],
    # 3-way join with USING and category lookups
    [:join_3way,        "SELECT f.title, c.name FROM sakila.film f JOIN sakila.film_category fc USING (film_id) JOIN sakila.category c USING (category_id)"],
    # Range scan
    [:range_scan,       "SELECT * FROM sakila.payment WHERE payment_date BETWEEN '2005-06-01' AND '2005-06-15'"],
    # COUNT(*) — common admin/dashboard shape
    [:count_all,        "SELECT COUNT(*) FROM sakila.rental"],
    # DISTINCT on a non-indexed column (forces temp table)
    [:distinct_tmp,     "SELECT DISTINCT rating FROM sakila.film"],
    # LIKE prefix (can use index)
    [:like_prefix,      "SELECT * FROM sakila.actor WHERE last_name LIKE 'S%'"],
  ].freeze

  # Runs each query in QUERIES `iterations` times. With the default
  # iterations=30 and 12 queries, that's 360 total statements — enough
  # to produce non-trivial count_star / sum_timer_wait values for each
  # digest without slowing the test suite down noticeably.
  def self.run!(connection, iterations: 30)
    QUERIES.each do |name, sql|
      iterations.times do
        connection.exec_query(sql)
      rescue StandardError => e
        raise "WorkloadGenerator: query `#{name}` failed: #{e.message}\nSQL: #{sql}"
      end
    end
  end
end
