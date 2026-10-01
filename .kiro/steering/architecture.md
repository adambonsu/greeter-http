---
inclusion: always
---
# Hexagonal architecture - greeter-http
- lib/greeter_http/application  use cases composing Greeter::Core
- lib/greeter_http/ports        abstract interfaces local to this service
- lib/greeter_http/adapters     all I/O: Lambda, DynamoDB, clock, presenters
- lib/greeter_http/app.rb       the ONLY composition root
- greeter-core is a dependency. Never reopen, monkey-patch, subclass or vendor anything in Greeter::Core. Compose only. If a task needs a core change, stop.
- Collaborators injected via keyword arguments. No globals.
- Ruby 3.3, frozen_string_literal, RuboCop clean.

Public API of the core gem:
#[[file:vendor/greeter-core-api.md]]