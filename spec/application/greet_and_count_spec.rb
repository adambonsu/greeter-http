# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'

RSpec.describe 'GreeterHttp::Application::GreetAndCount' do
  let(:clock)   { Greeter::Core::Testing::FixedClock.new }
  let(:counter) { GreeterHttp::Adapters::InMemoryGreetingCounter.new }
  let(:greeting_service) { Greeter::Core::Domain::GreetingService.new(clock: clock) }

  subject(:use_case) do
    GreeterHttp::Application::GreetAndCount.new(
      greeting_service: greeting_service,
      greeting_counter: counter
    )
  end

  def call(name, key: SecureRandom.uuid)
    use_case.call(raw_name: name, idempotency_key: key)
  end

  describe 'a valid greeting' do
    it 'returns the normalized guest name and a count of 1 for a new guest' do
      result = call('alice bonsu')

      expect(result.guest_name).to eq('Alice Bonsu')
      expect(result.count).to eq(1)
    end

    it 'increments the count on each distinct greeting of the same guest' do
      call('alice bonsu')
      result = call('alice bonsu')

      expect(result.count).to eq(2)
    end

    it 'stamps greeted_at from the injected clock' do
      result = call('alice bonsu')

      expect(result.greeted_at).to eq(clock.now)
    end
  end

  describe 'an invalid name' do
    it 'propagates InvalidGuestName from the core' do
      expect { call('') }
        .to raise_error(Greeter::Core::Domain::InvalidGuestName)
    end

    it 'does NOT increment the counter when the name is invalid' do
      begin
        call('')
      rescue Greeter::Core::Domain::InvalidGuestName
        # expected
      end

      # A subsequent valid greeting of a real guest must still start at 1,
      # proving the invalid attempt never touched the counter.
      expect(call('alice bonsu').count).to eq(1)
    end

    it 'never calls the counter for an invalid name' do
      spy_counter = instance_spy(GreeterHttp::Adapters::InMemoryGreetingCounter)
      use_case = GreeterHttp::Application::GreetAndCount.new(
        greeting_service: greeting_service,
        greeting_counter: spy_counter
      )

      begin
        use_case.call(raw_name: '', idempotency_key: 'k1')
      rescue Greeter::Core::Domain::InvalidGuestName
        # expected
      end

      expect(spy_counter).not_to have_received(:increment)
    end
  end
end
