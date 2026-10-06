# frozen_string_literal: true

require 'greeter/core'
require 'aws-sdk-dynamodb'

require 'greeter_http/application/greet_and_count'
require 'greeter_http/adapters/in_memory_greeting_counter'
require 'greeter_http/adapters/dynamodb_greeting_counter'
require 'greeter_http/adapters/system_clock'
require 'greeter_http/adapters/json_presenter'
require 'greeter_http/adapters/rack_app'
require 'greeter_http/adapters/lambda_handler'

module GreeterHttp
  # The ONLY composition root. This is the single place allowed to name
  # concrete adapter classes; everything else depends on ports.
  module App
    DEFAULT_TTL_SECONDS = 86_400

    module_function

    # Build the Rack application.
    #
    # @param greeting_counter [Ports::GreetingCounter, nil] injected counter;
    #   when nil, a DynamoDB-backed counter is constructed from the environment.
    # @param clock [#now] clock port; defaults to the system clock.
    def build(greeting_counter: nil, clock: Adapters::SystemClock.new)
      counter = greeting_counter || default_counter(clock)
      service = Greeter::Core::Domain::GreetingService.new(clock: clock)
      use_case = Application::GreetAndCount.new(
        greeting_service: service,
        greeting_counter: counter
      )
      Adapters::RackApp.new(use_case: use_case, presenter: Adapters::JsonPresenter.new)
    end

    # Build the Lambda handler wrapping the Rack app (production entry point).
    def build_handler(greeting_counter: nil, clock: Adapters::SystemClock.new)
      Adapters::LambdaHandler.new(app: build(greeting_counter: greeting_counter, clock: clock))
    end

    def default_counter(clock)
      Adapters::DynamoDbGreetingCounter.new(
        client: Aws::DynamoDB::Client.new,
        table_name: ENV.fetch('GREETER_TABLE_NAME'),
        ttl_seconds: Integer(ENV.fetch('GREETER_IDEMPOTENCY_TTL_SECONDS', DEFAULT_TTL_SECONDS)),
        clock: clock
      )
    end
  end
end
