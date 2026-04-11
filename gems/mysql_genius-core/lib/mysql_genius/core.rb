# frozen_string_literal: true

require "mysql_genius/core/version"

module MysqlGenius
  # The Rails-free core library. Consumed by both the `mysql_genius` Rails
  # adapter gem and (from Phase 2 onward) the `mysql_genius-desktop` gem.
  #
  # See `docs/superpowers/specs/2026-04-10-desktop-app-design.md` for the
  # overall design.
  module Core
    class Error < StandardError; end
  end
end

require "mysql_genius/core/result"
require "mysql_genius/core/server_info"
require "mysql_genius/core/column_definition"
require "mysql_genius/core/index_definition"
require "mysql_genius/core/sql_validator"
require "mysql_genius/core/connection"
require "mysql_genius/core/connection/fake_adapter"
require "mysql_genius/core/ai/config"
require "mysql_genius/core/ai/client"
require "mysql_genius/core/ai/suggestion"
require "mysql_genius/core/ai/optimization"
require "mysql_genius/core/analysis/table_sizes"
require "mysql_genius/core/analysis/duplicate_indexes"
require "mysql_genius/core/analysis/query_stats"
