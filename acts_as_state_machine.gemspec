$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "acts_as_state_machine/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "acts_as_state_machine"
  s.version     = ActsAsStateMachine::VERSION
  s.authors     = ["Chris Ortman"]
  s.email       = ["chrisortman@example.com"]
  s.homepage    = "None"
  s.summary     = "Fork of old project"
  s.description = "Fork of old project, runs on rails 3.2"

  s.files = Dir["{app,config,db,lib}/**/*"] + ["MIT-LICENSE", "Rakefile", "README.rdoc"]
  s.test_files = Dir["test/**/*"]

  s.add_dependency "rails", "~> 3.2"

  s.add_development_dependency "sqlite3"
end
