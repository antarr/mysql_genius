# frozen_string_literal: true

require "mysql_genius/core"
require "mysql_genius/desktop/version"
require "mysql_genius/core/connection/trilogy_adapter"

module MysqlGenius
  # Sinatra + Trilogy sidecar for serving the MysqlGenius dashboard against
  # an arbitrary MySQL/MariaDB server configured via a local YAML file.
  #
  # See `docs/superpowers/specs/2026-04-12-phase-2b-desktop-sidecar-design.md`.
  module Desktop
  end
end

# Concrete classes are required by later files as this plan progresses:
#   - require "mysql_genius/desktop/config/..."                (Tasks 4-5)
#   - require "mysql_genius/desktop/active_session"            (Task 6)
#   - require "mysql_genius/desktop/paths"                     (Task 7)
#   - require "mysql_genius/desktop/app"                       (Task 7)
#   - require "mysql_genius/desktop/launcher"                  (Task 15)
