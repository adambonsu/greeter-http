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

run GreeterHttp::App.build_from_env
