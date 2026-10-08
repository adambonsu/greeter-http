# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require_relative '../contracts/greeting_counter_contract'

# The in-memory adapter is the reference implementation used by application and
# acceptance tests. It must satisfy the same contract as the DynamoDB adapter.
RSpec.describe 'GreeterHttp::Adapters::InMemoryGreetingCounter' do
  # The full behavioral contract — counting, concurrency, and idempotency — is
  # defined once in 'a greeting counter' and shared with the DynamoDB adapter.
  it_behaves_like 'a greeting counter' do
    let(:counter) { GreeterHttp::Adapters::InMemoryGreetingCounter.new }
  end
end
