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
