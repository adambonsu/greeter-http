# frozen_string_literal: true

# Local development entry point: runs the Rack app directly (no Lambda, no SAM,
# no container). Start it with:
#
#   bundle exec rackup                       # in-memory counter (default)
#   GREETER_BACKEND=dynamodb \
#     GREETER_TABLE_NAME=greeter-http-local \
#     GREETER_DYNAMODB_ENDPOINT=http://localhost:8000 \
#     bundle exec rackup                      # against DynamoDB Local
#
# This is the same Rack app the Lambda handler drives in production, so routing,
# status codes, idempotency and JSON all behave identically.

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))

require 'greeter_http'

# Log which counter backend is wired at startup, so it's obvious whether the
# server is talking to DynamoDB or the in-memory store.
backend = ENV.fetch('GREETER_BACKEND', 'memory')
if backend == 'dynamodb'
  table = ENV.fetch('GREETER_TABLE_NAME', '(unset — GREETER_TABLE_NAME required)')
  endpoint = ENV.fetch('GREETER_DYNAMODB_ENDPOINT', nil)
  endpoint = '(AWS default regional endpoint)' if endpoint.nil? || endpoint.empty?
  warn "[greeter-http] backend=dynamodb table=#{table} endpoint=#{endpoint}"
else
  warn '[greeter-http] backend=memory (in-memory counter; data resets on restart)'
end

run GreeterHttp::App.build_from_env
