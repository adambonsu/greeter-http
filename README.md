# greeter-http

Exposes the [`greeter-core`](https://rubygems.org/gems/greeter-core) domain over
HTTP on AWS Lambda + API Gateway, and keeps a per-guest greeting count in
DynamoDB. Greeting the same guest increments a counter; retries are safe
(idempotent) and never double-count.

## What it does

A single endpoint, `POST /greetings`, greets a named guest and returns how many
times that guest has been greeted:

```
POST /greetings
Content-Type: application/json
Idempotency-Key: 7f3a-1c2b-91c

{ "name": "alice bonsu" }
```

```json
{
  "guest_name": "Alice Bonsu",
  "greeting": "Hello, Alice Bonsu!",
  "count": 1,
  "greeted_at": "2024-06-01T09:00:00Z"
}
```

Guest names are normalized by the domain (trimmed, titlecased), so
`"  alice bonsu "` and `"Alice Bonsu"` are the same guest and share one count.

### Idempotency

Every request must carry a client-supplied `Idempotency-Key` header.

- A **new** key greets the guest and increments the count — `201 Created`.
- Replaying the **same** key with the **same** body returns the original result
  without incrementing — `200 OK`, identical body.
- Reusing a key with a **different** body is rejected — `409 Conflict`.
- Keys are remembered for a bounded window (default 24h) and deduplicated across
  all keys in that window, not just the most recent one.

### Status codes

| Status | When |
| --- | --- |
| `201 Created` | first successful greeting for a key |
| `200 OK` | replay of a previously seen key + body |
| `400 Bad Request` | missing `Idempotency-Key`, or malformed JSON |
| `422 Unprocessable Entity` | invalid name (empty, too long, control chars) |
| `409 Conflict` | key reused with a different request |
| `503 Service Unavailable` | transient storage failure (retryable; sends `Retry-After`) |
| `500 Internal Server Error` | unexpected error |

## Architecture

Hexagonal, composing `greeter-core` without modifying it:

```
lib/greeter_http/
  application/   use cases (GreetAndCount) composing Greeter::Core
  ports/         abstract interfaces (GreetingCounter)
  adapters/      all I/O: Lambda handler, Rack app, DynamoDB, clock, presenter
  app.rb         the ONLY composition root (wires everything)
lib/lambda_function.rb   AWS Lambda entry point (handler)
infra/template.yaml      AWS SAM: Lambda, HTTP API, DynamoDB, IAM, alarms
```

The Lambda handler is a thin translator (API Gateway event <-> Rack); all HTTP
logic lives in the Rack app, and all business logic in `GreetAndCount`.

### Persistence

One DynamoDB table (on-demand, PITR + SSE), two item types sharing a guest
partition:

- **counter** item (`SK = "COUNTER"`) — the running count, never expires.
- **dedupe** item (`SK = "IKEY#<key>"`) — idempotency record with the request
  fingerprint and a TTL on `expires_at`.

Writes use a single optimistic-lock `TransactWriteItems` so the count is always
exact, even under concurrent requests and retries.

## Requirements

- Ruby 3.3.5 (see `.ruby-version` / `Gemfile`)
- Bundler
- For deploy / local invoke: the [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-install.html)
  and AWS credentials
- For the integration suite: Docker + DynamoDB Local (optional)

## Setup

```bash
bundle install
```

Smoke-check that the app loads:

```bash
bundle exec ruby -Ilib -e "require 'greeter_http'; puts 'ok'"
```

## Running the test suite

The behavior is fully exercised in-process (no AWS needed): unit specs, a Rack
app driven by `rack-test`, and Cucumber features that drive the Lambda handler
with built API Gateway events.

```bash
bundle exec rspec        # unit + adapter + contract specs
bundle exec cucumber     # end-to-end acceptance features
bundle exec rubocop      # lint
```

### Optional: integration specs against DynamoDB Local

These are tagged `:integration` and skipped unless `DYNAMODB_ENDPOINT` is set.

```bash
# start DynamoDB Local (example)
docker run -p 8000:8000 amazon/dynamodb-local

DYNAMODB_ENDPOINT=http://localhost:8000 bundle exec rspec spec/integration
```

## Interacting with the service

### Locally with the SAM CLI

Build and start the API on your machine (requires Docker + a local DynamoDB
table the function can reach):

```bash
sam build -t infra/template.yaml
sam local start-api -t infra/template.yaml
```

Then call it:

```bash
curl -i http://127.0.0.1:3000/greetings \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: demo-key-1' \
  -d '{"name":"alice bonsu"}'
```

Repeat the same command (same `Idempotency-Key`) and you'll get `200` with the
same `count`. Change the key and the count increments. Change the body under an
existing key and you'll get `409`.

### Invoking the handler directly

```bash
sam local invoke -t infra/template.yaml -e spec/fixtures/events/happy_path.json
```

(Event fixtures used by the tests live in `spec/fixtures/events/`.)

## Deploying

```bash
sam build -t infra/template.yaml
sam deploy --guided -t infra/template.yaml
```

The template provisions a Ruby 3.3 Lambda, an HTTP API (`POST /greetings` with
route throttling), the DynamoDB table (on-demand, PITR, SSE, TTL on
`expires_at`), a least-privilege execution role (`dynamodb:GetItem` +
`dynamodb:TransactWriteItems` on that one table), X-Ray tracing, 14-day log
retention, and CloudWatch alarms on 5xx rate and p95 latency.

`sam deploy` prints the API base URL as the `ApiBaseUrl` output. Then:

```bash
curl -i "$API_BASE_URL/greetings" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"name":"alice bonsu"}'
```

### Configuration

The function reads two environment variables (set by the SAM template):

| Variable | Meaning | Default |
| --- | --- | --- |
| `GREETER_TABLE_NAME` | DynamoDB table name | (from the stack) |
| `GREETER_IDEMPOTENCY_TTL_SECONDS` | idempotency retention window | `86400` (24h) |

### Smoke test against a deployed endpoint

The `@smoke` Cucumber feature runs against a real endpoint when
`GREETER_BASE_URL` is set, and is skipped otherwise:

```bash
GREETER_BASE_URL="$API_BASE_URL" bundle exec cucumber --tags @smoke
```

## Development notes

- `greeter-core` is a dependency and is never reopened, subclassed, or vendored —
  only composed.
- Specs and features map to the spec in
  `openspec/changes/.../specs/greeting-counter/spec.md`; each OpenSpec scenario
  has one `@requirement-greeting-counter` Cucumber scenario.
- Collaborators are injected via keyword arguments; `app.rb` is the only
  composition root.
