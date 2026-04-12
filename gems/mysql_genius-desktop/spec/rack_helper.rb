# frozen_string_literal: true

ENV["RACK_ENV"] ||= "test"

require "spec_helper"
require "rack/test"
require "mysql_genius/desktop"

module DesktopSpecSupport
  class FakeSession
    def initialize(adapter)
      @adapter = adapter
    end

    def checkout
      yield @adapter
    end

    def close; end
  end

  class << self
    def build_config(overrides = {})
      mysql = MysqlGenius::Desktop::Config::MysqlConfig.from_hash({ "host" => "localhost", "username" => "root", "database" => "test" })
      MysqlGenius::Desktop::Config.allocate.tap do |c|
        c.instance_variable_set(:@mysql, nil) # populated via active_mysql_config
        c.instance_variable_set(:@profiles, [MysqlGenius::Desktop::Config::ProfileConfig.new(name: "default", mysql: mysql)])
        c.instance_variable_set(:@default_profile, "default")
        c.instance_variable_set(:@server, MysqlGenius::Desktop::Config::ServerConfig.from_hash({}))
        c.instance_variable_set(:@security, MysqlGenius::Desktop::Config::SecurityConfig.from_hash(overrides.fetch(:security, {})))
        c.instance_variable_set(:@query, MysqlGenius::Desktop::Config::QueryConfig.from_hash(overrides.fetch(:query, {})))
        c.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.from_hash(overrides.fetch(:ai, {})))
        c.instance_variable_set(:@source_path, "(spec)")
      end
    end

    def build_fake_adapter
      MysqlGenius::Core::Connection::FakeAdapter.new
    end
  end
end

RSpec.configure do |config|
  config.include(Rack::Test::Methods, type: :request)

  config.before(:each, type: :request) do
    @fake_adapter = DesktopSpecSupport.build_fake_adapter
    @fake_adapter.stub_tables([])
    @test_config = DesktopSpecSupport.build_config
    MysqlGenius::Desktop::App.set(:mysql_genius_config, @test_config)
    MysqlGenius::Desktop::App.set(:active_session, DesktopSpecSupport::FakeSession.new(@fake_adapter))
    MysqlGenius::Desktop::App.set(:boot_token, "test-token")
    MysqlGenius::Desktop::App.set(:current_profile_name, "default")
    MysqlGenius::Desktop::App.set(:stats_history, nil)
    MysqlGenius::Desktop::App.set(:stats_collector, nil)
    set_cookie("mg_session=test-token")

    # Prevent real background threads from spawning in request specs.
    fake_collector = instance_double(MysqlGenius::Core::Analysis::StatsCollector, start: nil, stop: nil)
    allow(MysqlGenius::Core::Analysis::StatsCollector).to(receive(:new).and_return(fake_collector))
  end

  config.after(:each, type: :request) do
    MysqlGenius::Desktop::App.set(:mysql_genius_config, nil)
    MysqlGenius::Desktop::App.set(:active_session, nil)
    MysqlGenius::Desktop::App.set(:boot_token, nil)
    MysqlGenius::Desktop::App.set(:current_profile_name, nil)
    MysqlGenius::Desktop::App.set(:stats_history, nil)
    MysqlGenius::Desktop::App.set(:stats_collector, nil)
  end
end

def app
  MysqlGenius::Desktop::App
end
