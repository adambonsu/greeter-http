# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require_relative '../contracts/greeting_counter_contract'

# The in-memory adapter is the reference implementation used by application and
# acceptance tests. It must satisfy the same contract as the DynamoDB adapter.
RSpec.describe 'GreeterHttp::Adapters::InMemoryGreetingCounter' do
  subject(:counter) { GreeterHttp::Adapters::InMemoryGreetingCounter.new }

  it_behaves_like 'a greeting counter' do
    let(:counter) { GreeterHttp::Adapters::InMemoryGreetingCounter.new }
  end

  describe 'idempotency' do
    let(:guest) { "Guest #{SecureRandom.hex(4)}" }

    it 'replays the original count for a repeated key + matching fingerprint' do
      first = counter.increment(guest: guest, idempotency_key: 'k1', fingerprint: 'fp')
      replay = counter.increment(guest: guest, idempotency_key: 'k1', fingerprint: 'fp')

      expect(replay.count).to eq(first.count)
      expect(replay.replayed?).to be(true)
    end

    it 'does not change the stored count on replay' do
      counter.increment(guest: guest, idempotency_key: 'k1', fingerprint: 'fp')
      counter.increment(guest: guest, idempotency_key: 'k1', fingerprint: 'fp')
      after = counter.increment(guest: guest, idempotency_key: 'k2', fingerprint: 'fp')

      expect(after.count).to eq(2)
    end

    it 'raises KeyReused when a known key is used with a different fingerprint' do
      counter.increment(guest: guest, idempotency_key: 'k1', fingerprint: 'fp-a')

      expect do
        counter.increment(guest: guest, idempotency_key: 'k1', fingerprint: 'fp-b')
      end.to raise_error(GreeterHttp::Ports::GreetingCounter::KeyReused)
    end
  end
end
