# frozen_string_literal: true

# Minimal test harness for greeter-http.
#
# NOTE: this helper intentionally does NOT define or require any production
# classes (GreetAndCount, adapters, ports, app). Those are created during the
# apply phase. Until then these specs are expected to fail red for the right
# reason (NameError on the missing constants), per the TDD discipline.

require 'rspec'

# The domain core we compose against (safe to load; pure, no I/O).
require 'greeter/core'
require 'greeter/core/testing'

# Load the application under test if it exists yet. During test-first
# development it does not, so guard the require.
lib = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
begin
  require 'greeter_http'
rescue LoadError
  # Expected before the implementation exists.
end

# Shared examples live under spec/contracts and are loaded explicitly by the
# specs that use them, so no global requires here.

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Integration specs (e.g. DynamoDB Local) only run when explicitly enabled.
  config.filter_run_excluding(:integration) unless ENV['DYNAMODB_ENDPOINT']
end
