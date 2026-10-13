@smoke
Feature: Deployed smoke test

  Exercises a real deployed greeter-http endpoint over HTTP. These scenarios run
  only when GREETER_BASE_URL is set in the environment; when it is absent every
  scenario is skipped (see the Before hook for @smoke in the step definitions),
  so a normal local run never attempts a network call.

  Scenario: A greeting succeeds against the deployed service
    Given the deployed base URL from GREETER_BASE_URL
    When I POST a greeting for "alice bonsu" with a fresh idempotency key
    Then the HTTP status is 201
    And the JSON body has a "count" of 1
    And the JSON body "guest_name" is "Alice Bonsu"

  Scenario: Retrying a request against the deployed service does not double-count
    Given the deployed base URL from GREETER_BASE_URL
    And I POST a greeting for "carol kay" with idempotency key "smoke-fixed-key"
    When I POST the same greeting again with idempotency key "smoke-fixed-key"
    Then the HTTP status is 200
    And the JSON body "count" equals the first smoke response count

  # 0.2.0: names carrying HTML/template metacharacters are rejected at the
  # boundary (not greeted, not echoed).
  Scenario: A name with metacharacters is rejected
    Given the deployed base URL from GREETER_BASE_URL
    When I POST a greeting for "<script>alert(1)</script>" with a fresh idempotency key
    Then the HTTP status is 422
    And the JSON body "error" is "invalid_name"
    And the response body does not contain "<script>"

  # 0.2.0: an allowed punctuated name (apostrophe/hyphen) is still accepted, so
  # the guard does not over-reject real names.
  Scenario: An ordinary punctuated name is still accepted
    Given the deployed base URL from GREETER_BASE_URL
    When I POST a greeting for "jean-luc o'brien" with a fresh idempotency key
    Then the HTTP status is 201

  # 0.2.0: the request body is capped; an oversized body is rejected with 413.
  Scenario: An oversized request body is rejected
    Given the deployed base URL from GREETER_BASE_URL
    When I POST a greeting with a body larger than the cap
    Then the HTTP status is 413
