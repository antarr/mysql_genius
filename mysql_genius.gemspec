# frozen_string_literal: true

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "mysql_genius/version"

Gem::Specification.new do |spec|
  spec.name          = "mysql_genius"
  spec.version       = MysqlGenius::VERSION
  spec.authors       = ["Antarr Byrd"]
  spec.email         = ["antarr.t.byrd@uth.tmc.edu"]

  spec.summary       = "A MySQL performance dashboard and query explorer for Rails — like PgHero, but for MySQL."
  spec.description   = "MysqlGenius gives Rails apps a mountable performance dashboard for MySQL databases. " \
    "Monitor slow queries, analyze query statistics from performance_schema, detect unused and duplicate indexes, " \
    "and explore your database with optional AI-powered optimization."
  spec.homepage      = "https://github.com/antarr/mysql_genius"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path("..", __FILE__)) do
    %x(git ls-files -z).split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency("activerecord", ">= 5.2", "< 9")
  spec.add_dependency("mysql_genius-core", "~> 0.1.0.pre")
  spec.add_dependency("railties", ">= 5.2", "< 9")
end
