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

- Ruby 3.3.x (pinned to 3.3.5 locally via `.ruby-version`). The `Gemfile`
  deliberately carries no `ruby` directive so the Lambda `ruby3.3` managed
  runtime (currently a 3.3.x patch) is accepted at deploy time.
- Bundler
- For deploy / local build + invoke: the [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-install.html)
  (a recent version — `ruby3.3` support requires newer than 1.1xx) and Docker
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
This is the most reliable way to exercise the full DynamoDB happy path locally:
it drives the real `DynamoDbGreetingCounter` against DynamoDB Local, with no
Lambda-container credential plumbing in the way.

```bash
# start DynamoDB Local
docker run -p 8000:8000 amazon/dynamodb-local

DYNAMODB_ENDPOINT=http://localhost:8000 bundle exec rspec spec/integration
```

## Building

> **Always build with `--use-container`.** The Ruby bundle (including
> `greeter-core` and native extensions) must be compiled for the Lambda
> `ruby3.3` runtime. `--use-container` runs `bundle install` inside the AWS
> `build-ruby3.3` image so gems land under `vendor/bundle/ruby/3.3.0`. A plain
> `sam build` uses the host Ruby instead; if the host is on a different Ruby
> (this machine's default is a newer line), gems get vendored under the wrong
> ABI directory and the function fails at init with `cannot load such file`.

```bash
sam build --use-container -t infra/template.yaml
```

The build writes `.aws-sam/build/` (artifact + `template.yaml`). Run `sam local`
and `sam deploy` against that **built** template.

## Interacting with the service

### Locally with Rack (recommended for development)

The service is a Rack app with a thin Lambda adapter on top, so for day-to-day
development you can run the Rack app directly — no Lambda, no SAM, no container,
no AWS credentials. This exercises the exact same routing, status codes,
idempotency and JSON the deployed function uses.

```bash
bundle exec rackup          # in-memory counter (default), serves on :9292
```

```bash
curl -i http://127.0.0.1:9292/greetings \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: demo-key-1' \
  -d '{"name":"alice bonsu"}'
```

Backend is chosen by `GREETER_BACKEND`:

- `memory` (default) — in-memory counter, zero external dependencies.
- `dynamodb` — the real DynamoDB adapter. Point it at DynamoDB Local (which the
  host process reaches directly, no container networking):

  ```bash
  docker run -p 8000:8000 amazon/dynamodb-local   # in another terminal
  # create the table once (PK/SK, on-demand), then:
  GREETER_BACKEND=dynamodb \
    GREETER_TABLE_NAME=greeter-http-local \
    GREETER_DYNAMODB_ENDPOINT=http://localhost:8000 \
    bundle exec rackup
  ```

What `rackup` does NOT cover: the Lambda handler, the packaged artifact, and API
Gateway event translation. Use `sam local` (below) or a deploy to validate those.

### Locally with the SAM CLI

This validates the packaged Lambda artifact and the event→Rack translation.

```bash
sam build --use-container -t infra/template.yaml
sam local start-api -t .aws-sam/build/template.yaml   # note: the BUILT template
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

Without a reachable DynamoDB the endpoint returns `503` (datastore unavailable);
the rest of the pipeline still runs. To exercise the full path against DynamoDB
Local through `sam local`, three things must line up (all learned the hard way):

1. **DynamoDB Local must run with `-sharedDb`** so it ignores credential/region
   namespacing (otherwise the function and your `aws` CLI see different tables).
   The image's entrypoint is `java`, so the jar args come first:

   ```bash
   docker network create greeter-local
   docker run --rm --name ddb-shared --network greeter-local -p 8000:8000 \
     amazon/dynamodb-local -jar DynamoDBLocal.jar -inMemory -sharedDb
   # create the table once:
   aws dynamodb create-table --endpoint-url http://localhost:8000 \
     --table-name greeter-http-local --billing-mode PAY_PER_REQUEST \
     --attribute-definitions AttributeName=PK,AttributeType=S AttributeName=SK,AttributeType=S \
     --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE
   ```

2. **Both containers must share a user-defined network** (`--docker-network
   greeter-local`). The default `bridge` network has no DNS, so the Lambda
   container can only reach DynamoDB Local by name on a user-defined network.

3. **`GREETER_DYNAMODB_ENDPOINT` must be declared in the template** (it is) so
   SAM's `--env-vars` passes it through — SAM silently drops env-file keys that
   aren't declared under the function's `Environment.Variables`.

With an `env.json` like:

```json
{ "GreeterFunction": {
    "GREETER_TABLE_NAME": "greeter-http-local",
    "GREETER_DYNAMODB_ENDPOINT": "http://ddb-shared:8000"
} }
```

```bash
sam local invoke GreeterFunction -t .aws-sam/build/template.yaml \
  -e spec/fixtures/events/happy_path.json \
  --env-vars env.json --docker-network greeter-local
# => 201 the first time, 200 (same count) on replay
```

The composition root honors `GREETER_DYNAMODB_ENDPOINT` only for this local
path (unset in real AWS, where the SDK resolves the regional endpoint and task
credentials). For a quicker inner loop, the Rack path and the `:integration`
suite both avoid this container plumbing entirely.

### Invoking the handler directly

```bash
sam local invoke GreeterFunction -t .aws-sam/build/template.yaml \
  -e spec/fixtures/events/happy_path.json
```

(Event fixtures used by the tests live in `spec/fixtures/events/`.)

## Deploying

```bash
sam build --use-container -t infra/template.yaml
sam deploy --guided
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
