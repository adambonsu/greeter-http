# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'securerandom'

# Smoke steps run against a real deployed endpoint. When GREETER_BASE_URL is
# not set, every @smoke scenario is skipped so local/CI runs make no network
# calls.
Before('@smoke') do
  skip_this_scenario('GREETER_BASE_URL not set; skipping deployed smoke test') \
    if ENV['GREETER_BASE_URL'].to_s.empty?
end

def smoke_post(base_url, name, idempotency_key)
  uri = URI.join(base_url.chomp('/') + '/', 'greetings')
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  request = Net::HTTP::Post.new(uri)
  request['Content-Type'] = 'application/json'
  request['Idempotency-Key'] = idempotency_key
  request.body = JSON.generate({ name: name })
  http.request(request)
end

Given('the deployed base URL from GREETER_BASE_URL') do
  @base_url = ENV.fetch('GREETER_BASE_URL')
end

When('I POST a greeting for {string} with a fresh idempotency key') do |name|
  @response = smoke_post(@base_url, name, SecureRandom.uuid)
end

Given('I POST a greeting for {string} with idempotency key {string}') do |name, key|
  @response = smoke_post(@base_url, name, key)
  @first_smoke_count = JSON.parse(@response.body).fetch('count')
end

When('I POST the same greeting again with idempotency key {string}') do |key|
  @response = smoke_post(@base_url, 'carol kay', key)
end

Then('the HTTP status is {int}') do |status|
  expect(@response.code.to_i).to eq(status)
end

Then('the JSON body has a {string} of {int}') do |key, value|
  expect(JSON.parse(@response.body).fetch(key)).to eq(value)
end

Then('the JSON body {string} is {string}') do |key, value|
  expect(JSON.parse(@response.body).fetch(key)).to eq(value)
end

Then('the JSON body {string} equals the first smoke response count') do |key|
  expect(JSON.parse(@response.body).fetch(key)).to eq(@first_smoke_count)
end
