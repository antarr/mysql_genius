# frozen_string_literal: true

# Integration spec helper. Boots the spec/dummy/ Rails app and provides
# Rack::Test for request dispatch. Unit specs continue to use spec_helper.rb
# (no Rails boot).

# .rspec has `--require spec_helper`, so spec_helper is auto-loaded before
# rails_helper. spec_helper calls `require "mysql_genius"` when Rails is not
# yet defined, so lib/mysql_genius.rb skips `require "mysql_genius/engine"`
# (which is guarded by `if defined?(Rails)`). By the time the dummy app boots
# and application.rb calls `require "mysql_genius"`, the gem is already loaded
# and the require is a no-op — Engine is never defined.
#
# Fix: require Rails and the engine explicitly before booting the dummy app.
require "rails"
require "mysql_genius/engine"

# Stub ActiveRecord::Base before the dummy app boots, because Rails will
# try to reference it if any railtie reaches for it. We don't load the
# ActiveRecord railtie in the dummy app, so AR::Base is only referenced
# at test time through MysqlGenius's own code.
unless defined?(ActiveRecord::Base)
  module ActiveRecord
    class Base
      class << self
        def connection; end
      end
    end
  end
end

require_relative "dummy/config/environment"
require "rspec/rails"
require_relative "spec_helper"
require "rack/test"

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

# Provides the `app` method that Rack::Test::Methods expects as an instance
# method on each request spec example group.
module RackTestAppDefinition
  def app
    Rails.application
  end
end

RSpec.configure do |config|
  config.include(Rack::Test::Methods, type: :request)
  config.include(RackTestAppDefinition, type: :request)
  config.include(FakeConnectionHelper, type: :request)

  # Resets engine configuration before each request spec and installs a
  # permissive authenticate lambda. Specs that call reset_configuration!
  # again in their own `before` blocks will clobber this default and must
  # re-set authenticate themselves.
  config.before(:each, type: :request) do
    MysqlGenius.reset_configuration!
    MysqlGenius.configure do |c|
      c.authenticate = ->(_controller) { true }
    end
  end
end
