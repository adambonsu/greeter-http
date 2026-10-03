# greeter-core 0.1.2 — public API

Generated from the installed gem source (`greeter-core 0.1.2`). This is the
contract `greeter-http` composes against. Per the architecture rules, never
reopen, monkey-patch, subclass, or vendor anything here — compose only.

> There is **no** `Greeter::Core::Domain::GreetGuest`. The use case is
> `Greeter::Core::Domain::GreetingService#greet`.

## Domain

### `Greeter::Core::Domain::GreetingService`
The greeting use case. Pure: a name goes in, a `Greeting` value comes out,
timestamped via an injected clock. Knows nothing about counting or persistence.

- `.new(clock:)` — `clock` is any object responding to `#now` (a `Ports::Clock`).
- `#greet(raw_name) -> Greeting` — builds a `GuestName` from `raw_name` and
  stamps `greeted_at` with `clock.now`. Raises `InvalidGuestName` when the name
  is invalid.

```ruby
service  = Greeter::Core::Domain::GreetingService.new(clock: clock)
greeting = service.greet('alice bonsu')
greeting.guest_name.display # => "Alice Bonsu"
```

### `Greeter::Core::Domain::Greeting`
Frozen value object returned by `GreetingService#greet`.

- `#guest_name -> GuestName`
- `#greeted_at` — the `clock.now` value captured at greet time
- Constructed as `Greeting.new(guest_name:, greeted_at:)` (frozen on init)

### `Greeter::Core::Domain::GuestName`
Frozen value object. Validates, strips, and titlecases the raw name.

- `.new(raw)` — strips surrounding whitespace, titlecases
  (`"alice bonsu" -> "Alice Bonsu"`), then freezes. Raises `InvalidGuestName`
  when the name is empty, exceeds `MAX_LENGTH` (64), or contains control
  characters (`\x00-\x1F`, `\x7F`).
- `#display -> String` — the cleaned, titlecased name.
- `#== (other)` / `#eql?(other)` — equal when both are `GuestName` with the same
  `display`.
- `#hash` — consistent with `eql?` (safe as a Hash key / Set member).
- `MAX_LENGTH = 64`

### `Greeter::Core::Domain::InvalidGuestName`
`< ArgumentError`. Raised by `GuestName.new` (and therefore `GreetingService#greet`)
on invalid input.

## Ports (abstract interfaces defined by the core)

These are abstract base classes; their methods raise `NotImplementedError`.
Adapters in `greeter-http` provide concrete implementations.

### `Greeter::Core::Ports::Clock`
- `#now` — abstract. Return the current time.

### `Greeter::Core::Ports::GreetingPresenter`
- `#present(greeting)` — abstract. Note: `GreetingService` does **not** call this
  itself; it returns a raw `Greeting` and leaves presentation to the caller.

## Testing helpers

Require separately: `require 'greeter/core/testing'`.

### `Greeter::Core::Testing::FixedClock`
- `.new(time = Time.utc(2024, 6, 1, 9, 0, 0))`
- `#now -> time` — always returns the fixed time.

### `Greeter::Core::Testing::FakeClock`
- `.new(time)`
- `#now -> time` — returns the supplied time.

## Load paths

- `require 'greeter/core'` — loads ports, domain value objects, and
  `GreetingService`.
- `require 'greeter/core/testing'` — loads `FixedClock` and `FakeClock`.
