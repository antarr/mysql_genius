# frozen_string_literal: true

require "mysql_genius/core"
require "mysql_genius/desktop/version"
require "mysql_genius/core/connection/trilogy_adapter"
require "mysql_genius/desktop/config/mysql_config"
require "mysql_genius/desktop/config/server_config"
require "mysql_genius/desktop/config/security_config"
require "mysql_genius/desktop/config/query_config"
require "mysql_genius/desktop/config/ai_config"
require "mysql_genius/desktop/config/profile_config"
require "mysql_genius/desktop/config"
require "mysql_genius/desktop/active_session"
require "mysql_genius/desktop/database"
require "mysql_genius/desktop/sqlite_stats_history"
require "mysql_genius/desktop/profile_manager"
require "mysql_genius/desktop/session_swapper"
require "mysql_genius/desktop/paths"
require "mysql_genius/desktop/app"
require "mysql_genius/desktop/launcher"

module MysqlGenius
  # Sinatra + Trilogy sidecar for serving the MysqlGenius dashboard against
  # an arbitrary MySQL/MariaDB server configured via a local YAML file.
  #
  # See `docs/superpowers/specs/2026-04-12-phase-2b-desktop-sidecar-design.md`.
  module Desktop
  end

  # Minimal shim so shared ERB templates can call MysqlGenius.configuration
  # without depending on the Rails adapter's Configuration class.
  ConfigurationShim = Struct.new(:max_row_limit, :slow_query_threshold_ms, keyword_init: true)

  class << self
    def configuration
      @configuration ||= ConfigurationShim.new(max_row_limit: 10_000, slow_query_threshold_ms: 1000)
    end
  end
end
