# frozen_string_literal: true

source 'https://rubygems.org'
ruby '3.3.5'

# Domain core and ports, extracted into a standalone gem.
# Published at https://rubygems.org/gems/greeter-core
gem 'greeter-core', '~> 0.1'

gem 'aws-sdk-dynamodb', '~> 1'

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
