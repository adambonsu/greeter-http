# frozen_string_literal: true

# Behavioral contract shared by every GreetingCounter implementation
# (in-memory, DynamoDB, ...). Include it with a `subject` that is a fresh,
# empty counter:
#
#   it_behaves_like 'a greeting counter' do
#     let(:counter) { InMemoryGreetingCounter.new }
#   end
#
# Each implementation must satisfy the same observable behavior.
RSpec.shared_examples 'a greeting counter' do
  # Each example gets a distinct guest so parallel runs don't collide, and a
  # fresh idempotency key per call so these count-focused examples exercise
  # real increments rather than replays.
  def increment(guest, key: SecureRandom.uuid, fingerprint: nil)
    counter.increment(
      guest: guest,
      idempotency_key: key,
      fingerprint: fingerprint || "fp-#{guest}"
    )
  end

  def count_of(result)
    result.respond_to?(:count) ? result.count : result.fetch(:count)
  end

  let(:guest) { "Guest #{SecureRandom.hex(4)}" }

  it 'returns 1 on the first increment for a guest' do
    expect(count_of(increment(guest))).to eq(1)
  end

  it 'increases monotonically by one across successive increments' do
    counts = Array.new(5) { count_of(increment(guest)) }
    expect(counts).to eq([1, 2, 3, 4, 5])
  end

  it 'counts each guest independently' do
    alice = "Alice #{SecureRandom.hex(4)}"
    bob   = "Bob #{SecureRandom.hex(4)}"

    3.times { increment(alice) }
    1.times { increment(bob) }

    expect(count_of(increment(alice))).to eq(4)
    expect(count_of(increment(bob))).to eq(2)
  end

  it 'totals exactly 10 when 10 threads increment the same guest concurrently' do
    results = []
    mutex = Mutex.new

    threads = Array.new(10) do
      Thread.new do
        r = increment(guest)
        mutex.synchronize { results << count_of(r) }
      end
    end
    threads.each(&:join)

    # No lost updates: the 10 returned counts are exactly 1..10, and the final
    # observed value is 10.
    expect(results.sort).to eq((1..10).to_a)
  end
end
