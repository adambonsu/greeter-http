# frozen_string_literal: true

require 'json'
require 'rack'
require 'greeter/core'
require 'greeter_http/ports/greeting_counter'

module GreeterHttp
  module Adapters
    # Rack application owning HTTP concerns: routing (POST /greetings), JSON
    # parsing, Idempotency-Key extraction, response presentation, and mapping
    # domain/port errors to HTTP status. Business logic is delegated to the
    # injected GreetAndCount use case.
    class RackApp
      JSON_HEADERS = { 'content-type' => 'application/json' }.freeze

      # @param use_case [#call] GreetAndCount (keyword call: raw_name:, idempotency_key:)
      # @param presenter [#present] a GreetingPresenter adapter
      def initialize(use_case:, presenter:)
        @use_case = use_case
        @presenter = presenter
      end

      def call(env)
        request = Rack::Request.new(env)
        return error(404, 'not_found', 'Not found.') unless greetings_post?(request)

        handle_greeting(request)
      end

      private

      def greetings_post?(request)
        request.post? && request.path_info == '/greetings'
      end

      def handle_greeting(request)
        key = idempotency_key(request)
        return error(400, 'missing_idempotency_key', 'Idempotency-Key header is required.') if key.nil? || key.empty?

        name = parse_name(request)

        result = @use_case.call(raw_name: name, idempotency_key: key)
        success(result)
      rescue MalformedRequest
        error(400, 'malformed_request', 'Request body is not valid JSON.')
      rescue Greeter::Core::Domain::InvalidGuestName => e
        error(422, 'invalid_name', e.message)
      rescue Ports::GreetingCounter::KeyReused
        error(409, 'idempotency_key_reused',
              'This Idempotency-Key was already used for a different request.')
      rescue Ports::GreetingCounter::Unavailable => e
        # A genuine failure (not an expected 4xx) — log the cause so a 503 is
        # diagnosable in CloudWatch, then return the client-safe response.
        log_error('unavailable', e)
        unavailable
      rescue StandardError => e
        # Primary mapping of storage errors to a domain-neutral Unavailable
        # happens at the counter adapter boundary. This is defense-in-depth:
        # should any transient SDK error reach the HTTP boundary, answer 503
        # (retryable) rather than a permanent 500, and never leak it to the
        # client. Matched by class-name shape so this adapter neither references
        # an Aws:: constant nor hard-depends on the SDK being loaded.
        log_error('error', e)
        return unavailable if transient_service_error?(e)

        error(500, 'internal_error', 'An unexpected error occurred.')
      end

      def unavailable
        error(503, 'temporarily_unavailable', 'Please retry.', extra_headers: { 'retry-after' => '1' })
      end

      # Log a failed request to stderr (captured by CloudWatch) without leaking
      # anything to the client. No request content (e.g. guest name) is logged.
      def log_error(outcome, error)
        frame = Array(error.backtrace).first
        warn "[greeter-http] #{outcome}: #{error.class}: #{error.message}#{" @ #{frame}" if frame}"
      end

      # Matches any `Aws::<Service>::Errors::ServiceError` by ancestry name.
      def transient_service_error?(error)
        error.class.ancestors.any? do |ancestor|
          ancestor.name =~ /\AAws::\w+::Errors::ServiceError\z/
        end
      end

      class MalformedRequest < StandardError; end

      def idempotency_key(request)
        request.get_header('HTTP_IDEMPOTENCY_KEY')
      end

      def parse_name(request)
        body = request.body ? request.body.read : ''
        parsed = JSON.parse(body.to_s.empty? ? '{}' : body)
        raise MalformedRequest unless parsed.is_a?(Hash)

        parsed['name'].to_s
      rescue JSON::ParserError
        raise MalformedRequest
      end

      def success(result)
        status = result.replayed? ? 200 : 201
        body = @presenter.present_count(
          guest_name: result.guest_name,
          count: result.count,
          greeted_at: result.greeted_at
        )
        [status, JSON_HEADERS.dup, [JSON.generate(body)]]
      end

      def error(status, code, message, extra_headers: {})
        [status, JSON_HEADERS.merge(extra_headers), [JSON.generate(error: code, message: message)]]
      end
    end
  end
end
