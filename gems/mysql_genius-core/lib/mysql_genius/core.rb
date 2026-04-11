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

# Value objects and the connection contract. New requires get added in later
# tasks in this plan.
