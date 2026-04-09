# frozen_string_literal: true

require "bundler/setup"
require "mysql_genius"

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
