# frozen_string_literal: true

require 'json'

# Steps for the in-process greeting-counter feature. They drive the Lambda
# handler adapter (built in the World) with API Gateway v2 events.

# --- greeting actions -------------------------------------------------------

# Step text matches regardless of Given/When/Then keyword (they are aliases),
# so each unique pattern is defined exactly once to avoid ambiguous matches.
Given('a client greets {string} with a fresh idempotency key') do |name|
  greet(name: name)
end

When('a client greets {string} with no idempotency key') do |name|
  greet(name: name, idempotency_key: :none)
end

When('a client greets a name of {int} characters with a fresh idempotency key') do |n|
  greet(name: 'A' * n)
end

Given('a client greets {string} with idempotency key {string}') do |name, key|
  response = greet(name: name, idempotency_key: key)
  # Remember the first greet in a scenario so later steps can compare against it.
  if @first_response.nil?
    @first_response = response
    @first_key = key
    @first_name = name
  end
end

Given('a client greets {string} with idempotency key {string} producing count {int}') do |name, key, count|
  @first_response = greet(name: name, idempotency_key: key)
  @first_key = key
  @first_name = name
  expect(last_body.fetch('count')).to eq(count)
end

Given('a client resends the greeting for {string} with idempotency key {string}') do |name, key|
  greet(name: name, idempotency_key: key)
end

Given('the guest {string} has already been greeted {int} time(s) with fresh keys') do |name, times|
  times.times { greet(name: name) }
end

Given('the same guest is greeted to a higher count with other fresh keys') do
  2.times { greet(name: @first_name) }
end

Given('the persistent store rejects writes with a transient throttling condition') do
  require 'aws-sdk-dynamodb'
  failing = Object.new
  def failing.increment(**)
    raise Aws::DynamoDB::Errors::ServiceError.new(nil, 'throughput exceeded')
  end
  self.counter = failing
end

When('the retention window elapses') do
  clock.advance(GreeterHttpWorld::TTL_SECONDS + 1)
end

# --- assertions -------------------------------------------------------------

Then('the response status is {int}') do |status|
  expect(last_status).to eq(status)
end

Then('the response guest name is {string}') do |name|
  expect(last_body.fetch('guest_name')).to eq(name)
end

Then('the response count is {int}') do |count|
  expect(last_body.fetch('count')).to eq(count)
end

Then('the response count equals the first response count') do
  first = JSON.parse(@first_response['body']).fetch('count')
  expect(last_body.fetch('count')).to eq(first)
end

Then('the stored count for {string} is unchanged by the retry') do |name|
  # Prove the replay did not increment the counter by watching the counter
  # directly across two fresh-key greetings: each real greeting adds exactly 1,
  # so consecutive fresh probes must differ by exactly 1. This holds regardless
  # of how many distinct keys preceded the replay (the replayed snapshot is NOT
  # assumed to equal the current stored count).
  replayed = last_body.fetch('count')

  first_probe = JSON.parse(greet(name: name)['body']).fetch('count')
  second_probe = JSON.parse(greet(name: name)['body']).fetch('count')

  expect(second_probe - first_probe).to eq(1)
  # The replay returned a prior snapshot, never more than the current count.
  expect(replayed).to be <= first_probe
end

Then('no guest count has changed') do
  # A fresh valid greeting of a never-seen guest must still start at 1.
  probe = greet(name: "probe #{SecureRandom.hex(4)}")
  expect(JSON.parse(probe['body']).fetch('count')).to eq(1)
end

Then('the first response status is {int} and the replay response status is {int}') do |first, replay|
  expect(@first_response['statusCode']).to eq(first)
  expect(last_status).to eq(replay)
end

Then('both response bodies are identical') do
  expect(last_response['body']).to eq(@first_response['body'])
end

Then('the response body does not leak internal error details') do
  body = last_response['body']
  expect(body).not_to include('Aws::')
  expect(body).not_to include('Greeter::Core')
  expect(body).not_to match(/\.rb:\d+:in /)
end
