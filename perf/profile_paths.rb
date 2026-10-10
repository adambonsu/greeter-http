# frozen_string_literal: true

# Ad-hoc profiler comparing the latency distribution of the pure-compute
# use-case path (GreetAndCount#call) against the full handler path
# (LambdaHandler#call). Used to choose honest perf budgets.
#
#   bundle exec ruby perf/profile_paths.rb

$LOAD_PATH.unshift(File.join(__dir__, '..', 'lib'))
require 'greeter_http'
require 'json'
require 'securerandom'

def pct(sorted, p)
  sorted[((sorted.length * p).ceil - 1).clamp(0, sorted.length - 1)]
end

def dist(label, n)
  samples = Array.new(n) do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
  end.sort
  format('  %-22s p50=%.4f  p95=%.4f  p99=%.4f  max=%.4f ms',
         label, pct(samples, 0.50), pct(samples, 0.95), pct(samples, 0.99), samples.last)
end

counter = GreeterHttp::Adapters::InMemoryGreetingCounter.new
clock   = GreeterHttp::Adapters::SystemClock.new
service = Greeter::Core::Domain::GreetingService.new(clock: clock)
use_case = GreeterHttp::Application::GreetAndCount.new(greeting_service: service, greeting_counter: counter)

handler = GreeterHttp::Adapters::LambdaHandler.new(
  app: GreeterHttp::App.build(greeting_counter: GreeterHttp::Adapters::InMemoryGreetingCounter.new)
)

def event
  {
    'version' => '2.0', 'rawPath' => '/greetings',
    'headers' => { 'content-type' => 'application/json', 'idempotency-key' => SecureRandom.uuid },
    'requestContext' => { 'http' => { 'method' => 'POST', 'path' => '/greetings' } },
    'body' => JSON.generate('name' => 'alice bonsu'), 'isBase64Encoded' => false
  }
end

n = Integer(ENV.fetch('N', 50_000))
runs = Integer(ENV.fetch('RUNS', 3))

out = ENV['PROFILE_OUT'] ? File.open(ENV['PROFILE_OUT'], 'w') : $stdout

runs.times do |r|
  5_000.times { use_case.call(raw_name: 'alice bonsu', idempotency_key: SecureRandom.uuid) }
  5_000.times { handler.call(event: event) }
  out.puts "run #{r + 1}:"
  out.puts(dist('GreetAndCount#call', n) { use_case.call(raw_name: 'alice bonsu', idempotency_key: SecureRandom.uuid) })
  out.puts(dist('handler.call', n) { handler.call(event: event) })
  out.flush
end

out.close unless out == $stdout
