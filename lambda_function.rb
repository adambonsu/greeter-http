# frozen_string_literal: true

# AWS Lambda entry point. Lives at the deployment artifact root so the handler
# `lambda_function.handler` resolves inside /var/task. It adds lib/ to the load
# path and delegates to the composed app; no business logic lives here.

# Point RubyGems at the gems vendored under vendor/bundle by
# `sam build --use-container`, then require normally. Done in code (not via a
# GEM_PATH env var) because the managed runtime sets its own GEM_PATH and does
# not reliably honor a function-level override. '3.3.0' is the Ruby API (ABI)
# directory, stable across all 3.3.x patch releases.
require 'rubygems'
vendored_gems = File.expand_path('vendor/bundle/ruby/3.3.0', __dir__)
Gem.paths = { 'GEM_PATH' => [vendored_gems, *Gem.path].uniq.join(File::PATH_SEPARATOR) }

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))

require 'greeter_http'

HANDLER = GreeterHttp::App.build_handler

# @param event [Hash] API Gateway HTTP API (payload format 2.0) event
# @param context [Object] Lambda runtime context
def handler(event:, context: nil)
  HANDLER.call(event: event, context: context)
end
