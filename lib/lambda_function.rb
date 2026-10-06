# frozen_string_literal: true

# AWS Lambda entry point. The SAM template points its Handler at
# `lambda_function.handler`. Business logic lives behind the composed app;
# this file only wires and delegates.

require 'greeter_http'

HANDLER = GreeterHttp::App.build_handler

# @param event [Hash] API Gateway HTTP API (payload format 2.0) event
# @param context [Object] Lambda runtime context
def handler(event:, context: nil)
  HANDLER.call(event: event, context: context)
end
