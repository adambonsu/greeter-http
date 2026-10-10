# frozen_string_literal: true

# Performance benchmark for greeter-http.
#
# Two regimes:
#
#   1. In-process (pure compute). No network, no AWS. Two paths measured:
#      - GreetAndCount#call — the pure business logic (core greet + counter).
#        GATED: p99 > USE_CASE_BUDGET_MS fails, or >20% regression vs baseline.
#      - LambdaHandler#call — the full event->response path (JSON + Rack env +
#        presenter). REPORTED ONLY (benchmark-ips throughput + p99), NOT gated:
#        its tail is too noise-dominated in-process to police fairly.
#
#   2. Deployed (optional): a Ruby-thread load generator hitting
#      GREETER_BASE_URL with VUS virtual users for DURATION_S. Skipped unless
#      GREETER_BASE_URL is set. GATED: steady-state p95 > DEPLOYED_BUDGET_MS,
#      or >20% regression vs baseline. Cold start is reported SEPARATELY and
#      never counted in the steady-state p95.
#
# Budgets are set from observed reality on noisy shared hardware (dev laptop /
# CI runner), so the absolute gates are deliberately generous — the 20%
# regression check against a same-environment baseline is the sharper signal;
# the absolute budget is a backstop that should not cry wolf.
#
# Usage:
#   bundle exec ruby perf/http_bench.rb                 # in-process only
#   GREETER_BASE_URL=https://… bundle exec ruby perf/http_bench.rb   # + deployed
#
# First run writes perf/baseline.json; later runs compare against it.
#
# (A k6 script would be an alternative load generator; we use Ruby threads to
#  keep the harness self-contained in the existing Ruby/bundler toolchain with
#  no extra binary dependency.)

require 'json'
require 'time'
require 'securerandom'
require 'benchmark/ips'

$LOAD_PATH.unshift(File.join(__dir__, '..', 'lib'))
require 'greeter_http'

BASELINE_PATH = File.join(__dir__, 'baseline.json')

USE_CASE_BUDGET_MS = 10.0    # GATED: GreetAndCount#call p99 > 10 ms fails
DEPLOYED_BUDGET_MS = 300.0   # GATED: deployed steady-state p95 > 300 ms fails
REGRESSION_THRESHOLD = 1.20  # >20% worse than baseline fails
IN_PROCESS_SAMPLES = Integer(ENV.fetch('GREETER_PERF_SAMPLES', 50_000))
# Below this a relative regression check is dominated by clock jitter, so only
# the absolute budget applies (mirrors greeter-cli's perf gate).
NOISE_FLOOR_MS = 0.05

# The >20% regression check compares against a per-environment baseline. On
# shared CI runners a sub-5 ms microbenchmark's run-to-run p99 noise routinely
# exceeds 20% (a quiet run records ~1.5 ms, a busy run measures ~3.4 ms), so the
# relative check flaps against a lucky-fast cached baseline while telling us
# nothing real. The ABSOLUTE budget (USE_CASE_BUDGET_MS) is the stable signal
# there. Set GREETER_PERF_NO_REGRESSION=1 (CI does) to run the absolute gate
# only and still refresh the baseline; leave it unset locally, where the
# environment is stable enough for the relative check to be meaningful.
REGRESSION_CHECK = ENV['GREETER_PERF_NO_REGRESSION'].to_s.empty?

# Deployed load parameters. RATE is the target aggregate requests/second,
# paced to the service's configured capacity (the HttpApi stage throttles at
# RouteThrottleRate = 25 req/s). Driving at the rated limit measures latency
# under sustained load; overrunning it just trips the 429 throttle. Override
# GREETER_PERF_RATE to test a different capacity. A modest VU count is enough
# to sustain 25 req/s with headroom for per-request latency.
VUS        = Integer(ENV.fetch('GREETER_PERF_VUS', 10))
DURATION_S = Integer(ENV.fetch('GREETER_PERF_DURATION_S', 60))
RATE       = Integer(ENV.fetch('GREETER_PERF_RATE', 25))

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def percentile(sorted_ms, pct)
  return 0.0 if sorted_ms.empty?

  idx = (sorted_ms.length * pct).ceil - 1
  sorted_ms[idx.clamp(0, sorted_ms.length - 1)]
end

def sample_ms(iterations)
  Array.new(iterations) do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
  end
end

# ---------------------------------------------------------------------------
# In-process object graph: both the gated use-case path and the reported
# full-handler path, each over its own in-memory counter.
# ---------------------------------------------------------------------------

# Gated path: GreetAndCount#call (pure business logic — core greet + counter).
USE_CASE = GreeterHttp::Application::GreetAndCount.new(
  greeting_service: Greeter::Core::Domain::GreetingService.new(clock: GreeterHttp::Adapters::SystemClock.new),
  greeting_counter: GreeterHttp::Adapters::InMemoryGreetingCounter.new
)

# Reported path: the full Lambda handler (event -> JSON response).
HANDLER = GreeterHttp::Adapters::LambdaHandler.new(
  app: GreeterHttp::App.build(greeting_counter: GreeterHttp::Adapters::InMemoryGreetingCounter.new)
)

# A fresh idempotency key per call => a real increment each time, so we measure
# the write path, not the replay path.
def call_use_case
  USE_CASE.call(raw_name: 'alice bonsu', idempotency_key: SecureRandom.uuid)
end

# Build a fresh API Gateway v2 event with a unique idempotency key.
def build_event(name = 'alice bonsu')
  {
    'version' => '2.0',
    'routeKey' => 'POST /greetings',
    'rawPath' => '/greetings',
    'headers' => { 'content-type' => 'application/json', 'idempotency-key' => SecureRandom.uuid },
    'requestContext' => { 'http' => { 'method' => 'POST', 'path' => '/greetings' } },
    'body' => JSON.generate('name' => name),
    'isBase64Encoded' => false
  }
end

failures = []

# ---------------------------------------------------------------------------
# 1a. GreetAndCount#call — GATED pure-compute path
# ---------------------------------------------------------------------------

puts '=' * 64
puts 'In-process (GATED): GreetAndCount#call — pure business logic'
puts '=' * 64

2_000.times { call_use_case } # warm up
use_case_p99 = percentile(sample_ms(IN_PROCESS_SAMPLES) { call_use_case }.sort, 0.99)
puts format('  GreetAndCount#call p99 : %.4f ms (over %d samples)', use_case_p99, IN_PROCESS_SAMPLES)

if use_case_p99 >= USE_CASE_BUDGET_MS
  failures << format('GreetAndCount#call p99 %.4f ms exceeds %.1f ms budget', use_case_p99, USE_CASE_BUDGET_MS)
end

# ---------------------------------------------------------------------------
# 1b. LambdaHandler#call — REPORTED ONLY (not gated)
# ---------------------------------------------------------------------------

puts
puts '=' * 64
puts 'In-process (reported, not gated): LambdaHandler#call — full path'
puts '=' * 64

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)
  x.report('handler.call (full event -> response)') { HANDLER.call(event: build_event) }
end

2_000.times { HANDLER.call(event: build_event) } # warm up
handler_p99 = percentile(sample_ms(IN_PROCESS_SAMPLES) { HANDLER.call(event: build_event) }.sort, 0.99)
puts format('  handler.call p99 : %.4f ms (informational; not gated)', handler_p99)

# ---------------------------------------------------------------------------
# 2. Deployed load test (optional)
# ---------------------------------------------------------------------------

deployed = nil
base_url = ENV.fetch('GREETER_BASE_URL', nil)

if base_url.nil? || base_url.empty?
  puts
  puts 'Deployed load test skipped (GREETER_BASE_URL not set).'
else
  require_relative 'load'
  puts
  puts '=' * 64
  puts "Deployed load: #{VUS} VUs, ~#{RATE} req/s target for #{DURATION_S}s against #{base_url}"
  puts '=' * 64

  deployed = GreeterHttp::Perf::Load.run(base_url: base_url, vus: VUS, duration_s: DURATION_S, rate: RATE)

  puts format('  requests        : %d (%d ok, %d throttled, %d failed)',
              deployed[:total], deployed[:ok], deployed[:throttled], deployed[:failed])
  unless deployed[:failure_reasons].empty?
    puts '  failure breakdown:'
    deployed[:failure_reasons].each do |reason, count|
      puts format('    %-28s : %d', reason, count)
    end
  end
  puts format('  cold start      : %.1f ms (first request, client-observed)', deployed[:cold_start_ms])
  puts format('  steady-state p50: %.1f ms', deployed[:p50_ms])
  puts format('  steady-state p95: %.1f ms (cold start excluded)', deployed[:p95_ms])
  puts format('  steady-state p99: %.1f ms', deployed[:p99_ms])

  # HTTP 429 is expected backpressure above the configured rate, not a failure:
  # reported, never gated. Only hard failures (5xx, connection errors, non-429
  # 4xx) and the latency budget fail the run.
  if deployed[:throttled].positive?
    puts format('  note: %d requests throttled (HTTP 429) — expected above ~%d req/s, not counted as failures',
                deployed[:throttled], RATE)
  end
  if deployed[:failed].positive?
    failures << format('%d of %d deployed requests hard-failed (%s)',
                       deployed[:failed], deployed[:total], deployed[:failure_reasons].keys.join(', '))
  end
  if deployed[:p95_ms] >= DEPLOYED_BUDGET_MS
    failures << format('deployed p95 %.1f ms exceeds %.1f ms budget', deployed[:p95_ms], DEPLOYED_BUDGET_MS)
  end
end

# ---------------------------------------------------------------------------
# Baseline write / regression check
# ---------------------------------------------------------------------------

results = {
  'recorded_at' => Time.now.utc.iso8601,
  'use_case_p99_ms' => use_case_p99.round(6),   # gated
  'handler_p99_ms' => handler_p99.round(6)      # informational (not gated)
}
results['deployed_p95_ms'] = deployed[:p95_ms].round(3) if deployed

def check_regression(label, current, baseline_val, failures)
  return if baseline_val.nil? || baseline_val < NOISE_FLOOR_MS
  return unless current > baseline_val * REGRESSION_THRESHOLD

  failures << format(
    '%s %.4f ms is >%d%% worse than baseline %.4f ms',
    label, current, ((REGRESSION_THRESHOLD - 1) * 100).round, baseline_val
  )
end

if File.exist?(BASELINE_PATH)
  baseline = JSON.parse(File.read(BASELINE_PATH))

  puts
  if REGRESSION_CHECK
    puts '=' * 64
    puts "Regression check (threshold: >#{((REGRESSION_THRESHOLD - 1) * 100).round}% worse than baseline)"
    puts '=' * 64
    if baseline['use_case_p99_ms']
      puts format('  baseline GreetAndCount#call p99 : %.4f ms', baseline['use_case_p99_ms'])
    end
    if baseline['deployed_p95_ms']
      puts format('  baseline deployed p95           : %.1f ms',
                  baseline['deployed_p95_ms'])
    end

    # Only the gated metrics are regression-checked (handler p99 is informational).
    check_regression('GreetAndCount#call p99', use_case_p99, baseline['use_case_p99_ms'], failures)
    check_regression('deployed p95', deployed[:p95_ms], baseline['deployed_p95_ms'], failures) if deployed
  else
    puts 'Regression check skipped (GREETER_PERF_NO_REGRESSION set) — absolute budget only.'
  end

  # Merge: keep an existing deployed baseline when this run was in-process only,
  # so an in-process CI run doesn't erase the deployed baseline (and vice versa).
  merged = baseline.merge(results)
  File.write(BASELINE_PATH, JSON.pretty_generate(merged))
else
  File.write(BASELINE_PATH, JSON.pretty_generate(results))
  puts
  puts "Baseline written to #{BASELINE_PATH}"
end

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

puts
if failures.empty?
  puts 'All perf checks passed.'
else
  puts 'PERF FAILURES:'
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
