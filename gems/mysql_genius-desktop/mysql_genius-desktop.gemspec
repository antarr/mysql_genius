# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "mysql_genius/desktop/version"

Gem::Specification.new do |spec|
  spec.name          = "mysql_genius-desktop"
  spec.version       = MysqlGenius::Desktop::VERSION
  spec.authors       = ["Antarr Byrd"]
  spec.email         = ["antarr.t.byrd@uth.tmc.edu"]

  spec.summary       = "Terminal-launched Sinatra sidecar that serves the MysqlGenius dashboard against an arbitrary MySQL/MariaDB server."
  spec.description   = "The Rails-free sidecar companion to mysql_genius. Configure via YAML, run " \
    "`mysql-genius-sidecar --config ./mg.yml`, open the dashboard in a browser. " \
    "Uses mysql_genius-core for all analyses and the Trilogy client for MySQL I/O."
  spec.homepage      = "https://github.com/antarr/mysql_genius"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"]  = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/gems/mysql_genius-desktop/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    Dir.glob("lib/**/*.{rb,erb}") +
      Dir.glob("exe/*") +
      ["mysql_genius-desktop.gemspec", "CHANGELOG.md", "README.md", "TESTING.md"].select { |f| File.exist?(File.join(__dir__, f)) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency("mysql_genius-core", "~> 0.7.0")
  spec.add_dependency("puma", "~> 6.0")
  spec.add_dependency("sinatra", "~> 4.0")
  spec.add_dependency("sqlite3", "~> 2.0")
  spec.add_dependency("trilogy", "~> 2.9")
end
