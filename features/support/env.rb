# frozen_string_literal: true

# Cucumber world for greeter-http acceptance features.
#
# The in-process features drive the real Lambda handler adapter with built
# API Gateway v2 (payload format 2.0) events and an InMemoryGreetingCounter,
# so behavior is exercised end-to-end without AWS. The deployed smoke feature
# (@smoke) talks HTTP to ENV['GREETER_BASE_URL'] instead (see its steps).
#
# NOTE: production classes (GreeterHttp::*) do not exist until the apply phase.
# Until then these features fail red for the right reason (NameError), per the
# TDD discipline. We intentionally do NOT define them here.

$LOAD_PATH.unshift(File.join(__dir__, '..', '..', 'lib'))

require 'json'
require 'securerandom'

require 'greeter/core'
require 'greeter/core/testing'

begin
  require 'greeter_http'
rescue LoadError
  # Expected before the implementation exists.
end

module GreeterHttpWorld
  TTL_SECONDS = 86_400

  # A controllable clock so the retention-window feature can advance time.
  class MovableClock
    def initialize(now = Time.utc(2024, 6, 1, 9, 0, 0))
      @now = now
    end

    attr_accessor :now

    def advance(seconds)
      @now += seconds
    end
  end

  def clock
    @clock ||= MovableClock.new
  end

  # The in-memory counter backing the in-process handler. Built lazily so a
  # feature can swap in a failing double before the first request.
  def counter
    @counter ||= GreeterHttp::Adapters::InMemoryGreetingCounter.new(
      clock: clock,
      ttl_seconds: TTL_SECONDS
    )
  end

  attr_writer :counter

  def handler
    @handler ||= GreeterHttp::Adapters::LambdaHandler.new(
      app: GreeterHttp::App.build(greeting_counter: counter)
    )
  end

  # Build an API Gateway v2 (payload format 2.0) POST /greetings event.
  # Pass idempotency_key: :none to omit the header entirely.
  def build_event(name:, idempotency_key: SecureRandom.uuid)
    headers = { 'content-type' => 'application/json' }
    headers['idempotency-key'] = idempotency_key unless idempotency_key == :none

    {
      'version' => '2.0',
      'routeKey' => 'POST /greetings',
      'rawPath' => '/greetings',
      'rawQueryString' => '',
      'headers' => headers,
      'requestContext' => {
        'http' => { 'method' => 'POST', 'path' => '/greetings', 'protocol' => 'HTTP/1.1' }
      },
      'body' => JSON.generate({ 'name' => name }),
      'isBase64Encoded' => false
    }
  end

  # Build an event carrying a deliberately malformed JSON body.
  def build_malformed_event(idempotency_key: SecureRandom.uuid)
    build_event(name: 'x', idempotency_key: idempotency_key)
      .merge('body' => '{"name": "alice" ')
  end

  # Invoke the in-process handler and remember the last response.
  def greet(name:, idempotency_key: SecureRandom.uuid)
    @last_response = handler.call(event: build_event(name: name, idempotency_key: idempotency_key))
  end

  def invoke_event(event)
    @last_response = handler.call(event: event)
  end

  attr_reader :last_response

  def last_status
    last_response['statusCode']
  end

  def last_body
    JSON.parse(last_response['body'])
  end
end

World(GreeterHttpWorld)
