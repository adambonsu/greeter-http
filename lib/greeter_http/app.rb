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

    # Build the Rack app choosing a counter backend from the environment. Used
    # by config.ru for local development:
    #   GREETER_BACKEND=memory   (default) in-memory counter, zero dependencies
    #   GREETER_BACKEND=dynamodb DynamoDB-backed (needs GREETER_TABLE_NAME and,
    #                            for DynamoDB Local, GREETER_DYNAMODB_ENDPOINT)
    def build_from_env
      case ENV.fetch('GREETER_BACKEND', 'memory')
      when 'dynamodb'
        build
      else
        build(greeting_counter: Adapters::InMemoryGreetingCounter.new)
      end
    end

    def default_counter(clock)
      Adapters::DynamoDbGreetingCounter.new(
        client: dynamodb_client,
        table_name: ENV.fetch('GREETER_TABLE_NAME'),
        ttl_seconds: Integer(ENV.fetch('GREETER_IDEMPOTENCY_TTL_SECONDS', DEFAULT_TTL_SECONDS)),
        clock: clock
      )
    end

    # Honor an optional endpoint override so the function can run against a
    # local DynamoDB (e.g. DynamoDB Local via `sam local`). In AWS the variable
    # is unset and the SDK resolves the real regional endpoint and the task's
    # IAM credentials. For a local endpoint we also pass static dummy
    # credentials so DynamoDB Local accepts the request regardless of any
    # placeholder credentials the local runtime injected.
    def dynamodb_client
      endpoint = ENV.fetch('GREETER_DYNAMODB_ENDPOINT', nil)
      return Aws::DynamoDB::Client.new if endpoint.nil? || endpoint.empty?

      # DynamoDB Local accepts any credentials but rejects a session token it
      # cannot validate. Local runtimes (e.g. `sam local`) inject a placeholder
      # AWS_SESSION_TOKEN that the SDK would otherwise attach to the request, so
      # drop it on this local-only path before building the client.
      ENV.delete('AWS_SESSION_TOKEN')
      Aws::DynamoDB::Client.new(
        endpoint: endpoint,
        region: ENV.fetch('AWS_REGION', 'eu-west-1'),
        credentials: Aws::Credentials.new('local', 'local')
      )
    end
  end
end
