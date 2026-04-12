.PHONY: test test-rails test-core test-desktop lint lint-rails lint-core lint-desktop setup sidecar

# Run all test suites
test: test-rails test-core test-desktop

test-rails:
	bundle exec rspec

test-core:
	cd gems/mysql_genius-core && bundle exec rspec

test-desktop:
	cd gems/mysql_genius-desktop && bundle exec rspec

# Run all linters
lint: lint-rails lint-core lint-desktop

lint-rails:
	bundle exec rubocop

lint-core:
	cd gems/mysql_genius-core && bundle exec rubocop

lint-desktop:
	cd gems/mysql_genius-desktop && bundle exec rubocop

# Run everything (tests + lint)
check: test lint

# Install dependencies for all gems
setup:
	bundle install
	cd gems/mysql_genius-core && bundle install
	cd gems/mysql_genius-desktop && bundle install

# Start the desktop sidecar
# Usage: make sidecar CONFIG=/path/to/mg.yml
sidecar:
	cd gems/mysql_genius-desktop && bundle exec exe/mysql-genius-sidecar $(if $(CONFIG),--config $(CONFIG),)
