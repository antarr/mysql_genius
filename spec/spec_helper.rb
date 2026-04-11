# frozen_string_literal: true

require "bundler/setup"
require "mysql_genius"

# Regression guard: every constant the Rails concerns instantiate MUST be
# reachable via `require "mysql_genius"` alone — a host app's Rails boot
# does nothing more than load the gem, and if an adapter-side class like
# ActiveRecordAdapter is missing from the require chain in lib/mysql_genius.rb
# it will blow up with "uninitialized constant" the first time a controller
# action runs. Spec files that explicitly `require` the missing file would
# mask the bug, so we assert here at spec_helper load time (before any spec
# file has had a chance to require anything else).
unless defined?(MysqlGenius::Core::Connection::ActiveRecordAdapter)
  raise "Boot-order regression: MysqlGenius::Core::Connection::ActiveRecordAdapter " \
    "is not defined after `require \"mysql_genius\"`. Add a require for it to " \
    "lib/mysql_genius.rb so host apps can reach it without doing their own require."
end

$LOAD_PATH.unshift(File.expand_path("../app/services", __dir__))

# Stub ActiveRecord::Base.connection for service specs (avoids loading full ActiveRecord
# which has compatibility issues with system Ruby 2.6)
unless defined?(ActiveRecord::Base)
  module ActiveRecord
    class Base
      class << self
        def connection; end
      end
    end
  end
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with(:rspec) do |c|
    c.syntax = :expect
  end

  config.before do
    MysqlGenius.reset_configuration!
  end
end
