# frozen_string_literal: true

require 'spec_helper'

# Backend selection in the composition root. counter_from_env maps the
# GREETER_BACKEND env var to a concrete GreetingCounter adapter, with a
# per-entry-point default used when the var is unset (Lambda defaults to
# dynamodb; config.ru defaults to memory). These examples assert only the
# selected adapter CLASS and the error behaviour — no AWS I/O is performed
# (constructing the DynamoDB client is lazy; it makes no network call).
RSpec.describe 'GreeterHttp::App.counter_from_env' do
  # Snapshot and restore the env vars this method reads, so examples are
  # order-independent and never leak into the rest of the suite.
  ENV_KEYS = %w[GREETER_BACKEND GREETER_TABLE_NAME GREETER_IDEMPOTENCY_TTL_SECONDS AWS_REGION].freeze

  around do |example|
    saved = ENV_KEYS.to_h { |k| [k, ENV.fetch(k, nil)] }
    ENV_KEYS.each { |k| ENV.delete(k) }
    # DynamoDB adapter construction needs a table name + region (no I/O, but the
    # client needs a region to initialize); provide them for the dynamodb cases.
    ENV['GREETER_TABLE_NAME'] = 'test-table'
    ENV['AWS_REGION'] = 'eu-west-2'
    example.run
  ensure
    ENV_KEYS.each do |k|
      saved[k].nil? ? ENV.delete(k) : (ENV[k] = saved[k])
    end
  end

  def select(default:)
    GreeterHttp::App.counter_from_env(default: default)
  end

  describe 'when GREETER_BACKEND is unset (uses the given default)' do
    it "selects the in-memory counter for default 'memory'" do
      expect(select(default: 'memory')).to be_a(GreeterHttp::Adapters::InMemoryGreetingCounter)
    end

    it "selects the DynamoDB counter for default 'dynamodb'" do
      expect(select(default: 'dynamodb')).to be_a(GreeterHttp::Adapters::DynamoDbGreetingCounter)
    end
  end

  describe 'when GREETER_BACKEND is set (overrides the default)' do
    it "selects memory when GREETER_BACKEND=memory even if the default is 'dynamodb'" do
      ENV['GREETER_BACKEND'] = 'memory'
      expect(select(default: 'dynamodb')).to be_a(GreeterHttp::Adapters::InMemoryGreetingCounter)
    end

    it "selects DynamoDB when GREETER_BACKEND=dynamodb even if the default is 'memory'" do
      ENV['GREETER_BACKEND'] = 'dynamodb'
      expect(select(default: 'memory')).to be_a(GreeterHttp::Adapters::DynamoDbGreetingCounter)
    end
  end

  describe 'when GREETER_BACKEND names an unknown backend' do
    before { ENV['GREETER_BACKEND'] = 'bogus' }

    it 'raises ArgumentError (fail fast on a typo, no silent fallback)' do
      expect { select(default: 'memory') }.to raise_error(ArgumentError, /unknown GREETER_BACKEND/)
    end

    it 'names the offending value and the allowed backends in the message' do
      expect { select(default: 'memory') }
        .to raise_error(ArgumentError, /"bogus".*memory, dynamodb/)
    end
  end

  describe 'injecting a clock' do
    it 'accepts a clock and still selects by backend' do
      clock = Greeter::Core::Testing::FixedClock.new
      counter = GreeterHttp::App.counter_from_env(default: 'memory', clock: clock)
      expect(counter).to be_a(GreeterHttp::Adapters::InMemoryGreetingCounter)
    end
  end
end
