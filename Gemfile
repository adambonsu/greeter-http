# frozen_string_literal: true

source 'https://rubygems.org'

# No `ruby` version directive here: the Lambda ruby3.3 managed runtime provides
# the interpreter (currently a 3.3.x patch), and an exact pin here fails
# bundler's version check inside that runtime. The Ruby 3.3 family is pinned by
# the deploy runtime and local tooling, not by a Gemfile directive.

# Domain core and ports, extracted into a standalone gem.
# Published at https://rubygems.org/gems/greeter-core
gem 'greeter-core', '~> 0.1'

gem 'aws-sdk-dynamodb', '~> 1'
gem 'rack', '~> 3' # HTTP app the Lambda handler drives

group :development, :test do
  gem 'benchmark-ips'                   # micro-benchmarks
  gem 'brakeman', require: false        # static security analysis
  gem 'bundler-audit', require: false   # dependency CVE audit
  gem 'cucumber', '~> 9.2'
  gem 'rack-test'
  gem 'rspec', '~> 3.13'
  gem 'rubocop', require: false
  gem 'rubocop-rspec', require: false
  gem 'simplecov', require: false
end

# gem "rails"
