# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'securerandom'

# HTTP-boundary security properties for the greeter service, exercised end to
# end through the Lambda handler + Rack app over an in-memory counter (no AWS).
#
# These are behavioural guarantees a client/attacker can observe:
#   * raw request input is never reflected verbatim into a response body
#     (no stored/reflected XSS, no echoing of attacker-controlled strings),
#   * no permissive CORS (no access-control-* headers, never a "*" origin),
#   * the request body is capped (a giant body is rejected, not processed),
#   * every malformed/hostile fixture gets a safe, documented 4xx — never a
#     5xx and never a leaked internal.
#
# The fixture statuses are intentional and already contracted in
# spec/adapters/lambda_handler_spec.rb: malformed JSON => 400, but a
# semantically invalid name (empty / too long) => 422. "Malformed" here means
# "not a valid request", and the security property is that each is handled
# safely with the correct 4xx — not that all collapse to 400.
RSpec.describe 'HTTP security properties' do
  FIXTURES = File.expand_path('../fixtures/events', __dir__)

  let(:handler) do
    GreeterHttp::App.build_handler(
      greeting_counter: GreeterHttp::Adapters::InMemoryGreetingCounter.new
    )
  end

  def load_event(name)
    JSON.parse(File.read(File.join(FIXTURES, "#{name}.json")))
  end

  # Build an API Gateway v2 event with the given raw name and (optional) body
  # override, each with a fresh idempotency key.
  def event_for(name: nil, raw_body: nil, headers: {})
    base_headers = { 'content-type' => 'application/json', 'idempotency-key' => SecureRandom.uuid }
    body = raw_body || JSON.generate('name' => name)
    {
      'version' => '2.0',
      'routeKey' => 'POST /greetings',
      'rawPath' => '/greetings',
      'rawQueryString' => '',
      'headers' => base_headers.merge(headers),
      'requestContext' => { 'http' => { 'method' => 'POST', 'path' => '/greetings' } },
      'body' => body,
      'isBase64Encoded' => false
    }
  end

  describe 'no raw input reflected in response bodies' do
    # Each payload carries a distinctive sentinel that must NOT appear verbatim
    # in any response. Includes classic reflected-XSS and template/HTML probes.
    hostile_names = [
      '<script>alert(1)</script>',
      '"><img src=x onerror=alert(1)>',
      '{{7*7}}',
      "'; DROP TABLE greetings; --",
      "line1\u0000line2" # control char => InvalidGuestName
    ]

    hostile_names.each do |payload|
      it "does not echo #{payload.inspect} verbatim in the body" do
        response = handler.call(event: event_for(name: payload))
        body = response['body']

        # The raw payload (and its most dangerous substrings) never appears.
        expect(body).not_to include(payload)
        expect(body).not_to include('<script>')
        expect(body).not_to include('onerror=')
        expect(body).not_to include('DROP TABLE')
      end
    end

    it 'returns only a fixed code + static message on an invalid name (no reflection)' do
      response = handler.call(event: event_for(name: '<script>'))
      parsed = JSON.parse(response['body'])

      expect(response['statusCode']).to eq(422)
      expect(parsed.keys).to contain_exactly('error', 'message')
      expect(parsed['error']).to eq('invalid_name')
      # The core's validation messages are static; assert the message is one of
      # them and contains none of the raw input.
      expect(parsed['message']).not_to include('<script>')
      expect(parsed['message']).to match(/\AName (must not|contains)/)
    end

    it 'titlecases a benign name without reflecting unexpected markup' do
      response = handler.call(event: event_for(name: 'alice bonsu'))
      body = JSON.parse(response['body'])

      expect(response['statusCode']).to eq(201)
      expect(body['guest_name']).to eq('Alice Bonsu')
      expect(response['body']).not_to match(/[<>]/) # no angle brackets anywhere
    end
  end

  describe 'no permissive CORS' do
    it 'sets no access-control-* headers on a success response' do
      response = handler.call(event: event_for(name: 'alice bonsu'))
      cors = response['headers'].keys.select { |k| k.to_s.downcase.start_with?('access-control-') }
      expect(cors).to be_empty
    end

    it 'sets no access-control-* headers on an error response' do
      response = handler.call(event: event_for(name: ''))
      cors = response['headers'].keys.select { |k| k.to_s.downcase.start_with?('access-control-') }
      expect(cors).to be_empty
    end

    it 'never emits a wildcard allow-origin anywhere in the response' do
      response = handler.call(event: event_for(name: 'alice bonsu'))
      header_values = response['headers'].map { |_k, v| v.to_s }
      expect(header_values).not_to include('*')
      expect(response['headers'].keys.map { |k| k.to_s.downcase }).not_to include('access-control-allow-origin')
    end
  end

  describe 'request body is capped' do
    it 'rejects an oversized body with 413 instead of processing it' do
      # Far larger than MAX_BODY_BYTES; a valid-looking JSON object so the only
      # reason to reject is size, not malformed JSON.
      huge = JSON.generate('name' => 'a' * (64 * 1024))
      response = handler.call(event: event_for(raw_body: huge))

      expect(response['statusCode']).to eq(413)
      expect(JSON.parse(response['body'])['error']).to eq('payload_too_large')
    end

    it 'rejects an oversized body even when Content-Length is understated' do
      huge = JSON.generate('name' => 'a' * (64 * 1024))
      # Lie about the length; the capped read must still stop it.
      response = handler.call(event: event_for(raw_body: huge, headers: { 'content-length' => '10' }))

      expect(response['statusCode']).to eq(413)
    end

    it 'accepts a normal small body' do
      response = handler.call(event: event_for(name: 'alice bonsu'))
      expect(response['statusCode']).to eq(201)
    end
  end

  describe 'every malformed fixture is handled safely' do
    # Documented, intentional statuses (see lambda_handler_spec.rb).
    expected = {
      'malformed_json' => 400, # body is not valid JSON
      'missing_name' => 422,   # empty name — semantically invalid
      'oversized_name' => 422  # name exceeds core MAX_LENGTH
    }

    expected.each do |fixture, status|
      context "the #{fixture} fixture" do
        subject(:response) { handler.call(event: load_event(fixture)) }

        it "returns #{status}" do
          expect(response['statusCode']).to eq(status)
        end

        it 'returns a safe JSON error object (code + message only)' do
          parsed = JSON.parse(response['body'])
          expect(parsed).to be_a(Hash)
          expect(parsed.keys).to contain_exactly('error', 'message')
        end

        it 'never returns 5xx and never leaks internals' do
          expect(response['statusCode']).to be < 500
          expect(response['body']).not_to include('Aws::')
          expect(response['body']).not_to include('Greeter::Core')
          expect(response['body']).not_to match(/\.rb:\d+:in /)
        end
      end
    end
  end
end
