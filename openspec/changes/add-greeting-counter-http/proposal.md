# Proposal

## Why

`greeter-http` currently exposes nothing: the `greeter-core` domain exists but is
not reachable over HTTP, and there is no record of how often each guest has been
greeted. We want to serve the core use case on AWS Lambda + API Gateway and keep a
per-guest greeting count in DynamoDB, with safe behavior under the at-least-once
delivery that Lambda/API Gateway imply (retries must not double-count).

## What Changes

- Add an HTTP endpoint `POST /greetings` that greets a guest and returns a running
  per-guest greeting count.
- Compose the installed `greeter-core` use case (`GreetingService#greet`) with a new
  local `GreetingCounter` port; never modify, subclass, or reopen the core gem.
- Persist a per-guest counter in DynamoDB and increment it atomically.
- Require a client-supplied `Idempotency-Key` header and make the endpoint
  idempotent: a replayed key returns the original result (hybrid replay-with-
  fingerprint); the same key with a different request body is rejected.
- Deduplicate across all idempotency keys for a configurable TTL window (default 24h)
  using per-key dedupe items with DynamoDB TTL.
- Deliver the service as a thin AWS Lambda handler adapter over a Rack application,
  with `app.rb` as the single composition root.

## Capabilities

### New Capabilities
- `greeting-counter`: Greet a guest over HTTP, return a per-guest greeting count,
  and guarantee idempotent, non-double-counting behavior under client retries.

### Modified Capabilities
<!-- None. greeter-core is an external dependency and is not modified. -->

## Impact

- **New code** (hexagonal layout in `lib/greeter_http/`):
  - `application/greet_and_count` — composes core + the counter port.
  - `ports/greeting_counter` — abstract port local to this service.
  - `adapters/` — DynamoDB counter adapter, Rack app, Lambda handler, presenter, clock.
  - `app.rb` — composition root wiring all collaborators.
- **Dependencies**: `greeter-core` (compose only), `aws-sdk-dynamodb`, `rack`;
  `rack-test`, `rspec`, `cucumber` for tests. All already present in the Gemfile.
- **AWS**: one DynamoDB table (counter items + TTL'd dedupe items), a Lambda function,
  and an API Gateway route. Table requires TTL enabled on the `expires_at` attribute.
- **Contract**: new public HTTP API (`POST /greetings`) with defined status codes
  (201/200/400/422/409/503) and JSON bodies.
- **No change** to `greeter-core`; `vendor/greeter-core-api.md` documents the composed surface.
