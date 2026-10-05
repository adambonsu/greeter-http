# frozen_string_literal: true

require 'spec_helper'

# greeter-core 0.1.2 ships test doubles (FixedClock/FakeClock) but NO rspec
# shared examples. These local contracts assert that our adapters conform to
# the gem's abstract ports:
#   Greeter::Core::Ports::Clock#now
#   Greeter::Core::Ports::GreetingPresenter#present(greeting)
# They are authored here deliberately; see openspec change
# add-greeting-counter-http (item 4, option 1).

RSpec.shared_examples 'a clock' do
  it 'is substitutable for the core Clock port' do
    expect(clock).to be_a(Greeter::Core::Ports::Clock)
  end

  it 'responds to #now' do
    expect(clock).to respond_to(:now)
  end

  it 'returns a Time from #now' do
    expect(clock.now).to be_a(Time)
  end

  it 'returns a UTC time' do
    expect(clock.now.utc?).to be(true)
  end
end

RSpec.shared_examples 'a greeting presenter' do
  let(:greeting) do
    Greeter::Core::Domain::GreetingService
      .new(clock: Greeter::Core::Testing::FixedClock.new)
      .greet('alice bonsu')
  end

  it 'is substitutable for the core GreetingPresenter port' do
    expect(presenter).to be_a(Greeter::Core::Ports::GreetingPresenter)
  end

  it 'responds to #present' do
    expect(presenter).to respond_to(:present)
  end

  it 'presents a greeting as a JSON-ready hash with the expected keys' do
    result = presenter.present(greeting)
    expect(result).to include(
      guest_name: 'Alice Bonsu',
      greeting: 'Hello, Alice Bonsu!'
    )
    expect(result).to have_key(:greeted_at)
  end
end

RSpec.describe 'core port conformance' do
  describe 'GreeterHttp::Adapters::SystemClock' do
    it_behaves_like 'a clock' do
      let(:clock) { GreeterHttp::Adapters::SystemClock.new }
    end
  end

  describe 'GreeterHttp::Adapters::JsonPresenter' do
    it_behaves_like 'a greeting presenter' do
      let(:presenter) { GreeterHttp::Adapters::JsonPresenter.new }
    end
  end
end
