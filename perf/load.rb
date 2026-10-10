# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'securerandom'

module GreeterHttp
  module Perf
    # Ruby-thread load generator for the deployed endpoint. VUS threads each
    # issue POST /greetings in a loop for DURATION_S, recording per-request
    # latency. The very first successful request (across all VUs) is captured
    # separately as the client-observed cold start and excluded from the
    # steady-state percentiles, so a Lambda cold start never skews the p95 gate.
    #
    # Only Ruby stdlib is used (net/http) — no k6 binary required. A k6 script
    # would be a drop-in alternative if preferred in CI.
    module Load
      module_function

      def run(base_url:, vus:, duration_s:)
        uri = URI.join("#{base_url.chomp('/')}/", 'greetings')
        deadline = monotonic + duration_s

        latencies = Array.new(vus) { [] } # per-thread, lock-free
        oks = Array.new(vus, 0)
        fails = Array.new(vus, 0)
        cold_start_ms = nil
        cold_mutex = Mutex.new

        threads = Array.new(vus) do |i|
          Thread.new do
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == 'https')
            http.keep_alive_timeout = 10
            http.start

            while monotonic < deadline
              t0 = monotonic
              ok = attempt(http, uri)
              elapsed_ms = (monotonic - t0) * 1000.0

              first = cold_mutex.synchronize do
                if cold_start_ms.nil? && ok
                  cold_start_ms = elapsed_ms
                  true
                else
                  false
                end
              end

              if ok
                oks[i] += 1
                latencies[i] << elapsed_ms unless first # exclude cold start from steady state
              else
                fails[i] += 1
              end
            end

            http.finish if http.started?
          end
        end
        threads.each(&:join)

        steady = latencies.flatten.sort
        {
          total: oks.sum + fails.sum,
          ok: oks.sum,
          failed: fails.sum,
          cold_start_ms: cold_start_ms || 0.0,
          p50_ms: pct(steady, 0.50),
          p95_ms: pct(steady, 0.95),
          p99_ms: pct(steady, 0.99)
        }
      end

      def attempt(http, uri)
        req = Net::HTTP::Post.new(uri)
        req['Content-Type'] = 'application/json'
        req['Idempotency-Key'] = SecureRandom.uuid
        req.body = JSON.generate('name' => 'alice bonsu')
        resp = http.request(req)
        # 201 (created) and 200 (replay) are both success; anything else is a failure.
        %w[200 201].include?(resp.code)
      rescue StandardError
        false
      end

      def pct(sorted, p)
        return 0.0 if sorted.empty?

        idx = (sorted.length * p).ceil - 1
        sorted[idx.clamp(0, sorted.length - 1)]
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
