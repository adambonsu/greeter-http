# frozen_string_literal: true

# Reports the Lambda cold-start **Init Duration** as measured by the runtime
# itself and recorded in CloudWatch — the authoritative figure, reported
# SEPARATELY from the client-observed cold start in http_bench.rb (they measure
# different things: client cold start includes network + API Gateway + init +
# first handler run; Init Duration is only the runtime/init phase).
#
# Usage (needs AWS creds; defaults to the greeter-dev profile and eu-west-2):
#   bundle exec ruby perf/cloudwatch_init_duration.rb --stack sam-app
#   STACK=sam-app AWS_PROFILE=greeter-dev AWS_REGION=eu-west-2 \
#     bundle exec ruby perf/cloudwatch_init_duration.rb
#
# It shells out to the AWS CLI so it needs no extra gems. Read-only.

require 'json'
require 'open3'

STACK   = ENV.fetch('STACK', 'sam-app')
REGION  = ENV.fetch('AWS_REGION', 'eu-west-2')
PROFILE = ENV.fetch('AWS_PROFILE', 'greeter-dev')
WINDOW_MINUTES = Integer(ENV.fetch('WINDOW_MINUTES', 60))

def aws(*args)
  cmd = ['aws', *args, '--region', REGION, '--profile', PROFILE, '--output', 'json']
  out, err, status = Open3.capture3(*cmd)
  raise "aws #{args.first} failed: #{err.strip}" unless status.success?

  out.empty? ? nil : JSON.parse(out)
end

# Resolve the function's log group from the stack.
fn = aws('cloudformation', 'describe-stack-resources',
         '--stack-name', STACK,
         '--logical-resource-id', 'GreeterFunction')
function_name = fn.fetch('StackResources').first.fetch('PhysicalResourceId')
log_group = "/aws/lambda/#{function_name}"

start_ms = ((Time.now.to_i - (WINDOW_MINUTES * 60)) * 1000)

# REPORT lines carry "Init Duration: <n> ms" only for cold starts. Filter for them.
events = aws('logs', 'filter-log-events',
             '--log-group-name', log_group,
             '--start-time', start_ms.to_s,
             '--filter-pattern', 'Init Duration')

messages = (events&.fetch('events', []) || []).map { |e| e['message'].to_s }
inits = messages.filter_map do |m|
  m[/Init Duration:\s*([\d.]+)\s*ms/, 1]&.to_f
end

puts '=' * 64
puts "CloudWatch Init Duration (cold starts) — #{function_name}"
puts "window: last #{WINDOW_MINUTES} min   region: #{REGION}   profile: #{PROFILE}"
puts '=' * 64

if inits.empty?
  puts '  no cold starts recorded in the window (function stayed warm, or no'
  puts '  invocations). Trigger a cold start by deploying or waiting for the'
  puts '  execution environment to recycle, then re-run.'
else
  sorted = inits.sort
  puts format('  cold starts     : %d', sorted.length)
  puts format('  init min / max  : %.1f ms / %.1f ms', sorted.first, sorted.last)
  puts format('  init mean       : %.1f ms', sorted.sum / sorted.length)
  puts format('  init p95        : %.1f ms', sorted[(sorted.length * 0.95).ceil - 1])
end
