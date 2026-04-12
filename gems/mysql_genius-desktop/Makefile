.PHONY: start test lint clean

# Start the sidecar against a local MySQL
# Usage: make start CONFIG=/path/to/mg.yml
# Default: looks for ~/.mysql_genius.yml or ./mysql_genius.yml
start:
	bundle exec exe/mysql-genius-sidecar $(if $(CONFIG),--config $(CONFIG),)

# Run all specs
test:
	bundle exec rspec

# Run linter
lint:
	bundle exec rubocop

# Install dependencies
setup:
	bundle install

# Start with a specific port
# Usage: make start-port PORT=8080
start-port:
	bundle exec exe/mysql-genius-sidecar --port $(PORT) $(if $(CONFIG),--config $(CONFIG),)
