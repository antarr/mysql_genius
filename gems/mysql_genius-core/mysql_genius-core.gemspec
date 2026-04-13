# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "mysql_genius/core/version"

Gem::Specification.new do |spec|
  spec.name          = "mysql_genius-core"
  spec.version       = MysqlGenius::Core::VERSION
  spec.authors       = ["Antarr Byrd"]
  spec.email         = ["antarr.t.byrd@uth.tmc.edu"]

  spec.summary       = "Rails-free core library for MysqlGenius — validators, analyses, AI services."
  spec.description   = "Shared library used by the mysql_genius Rails engine and the mysql_genius-desktop " \
    "standalone app. Contains the SQL validator, query runner, database analyses, and AI services, all of " \
    "which take an explicit connection abstraction (no globals, no ActiveRecord dependency)."
  spec.homepage      = "https://github.com/antarr/mysql_genius"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/gems/mysql_genius-core/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    Dir.glob("lib/**/*.{rb,erb}") + ["mysql_genius-core.gemspec", "CHANGELOG.md", "README.md"].select { |f| File.exist?(File.join(__dir__, f)) }
  end
  spec.require_paths = ["lib"]

  # No runtime dependencies — core is intentionally stdlib-only.
  # (trilogy is a Phase 2 addition for the desktop adapter; the Rails adapter
  # brings its own ActiveRecord connection.)
end
