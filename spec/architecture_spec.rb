# frozen_string_literal: true

require 'spec_helper'

# Enforces the hexagonal boundaries for greeter-http (see
# .kiro/steering/architecture.md and the add-greeting-counter-http design):
#
#  * app.rb is the ONLY composition root; it is the only place allowed to
#    name concrete adapter constants. Everything else depends on ports.
#  * Nothing may reopen / monkey-patch / subclass a Greeter::Core class.
RSpec.describe 'architecture boundaries' do
  LIB_DIR = File.expand_path('../lib', __dir__)

  def ruby_files
    Dir.glob(File.join(LIB_DIR, '**', '*.rb'))
  end

  it 'has a lib/ directory with source files to analyze' do
    # Guards against a false green when the implementation does not exist yet.
    expect(ruby_files).not_to be_empty
  end

  # Concrete adapter class names that only the composition root may reference.
  CONCRETE_ADAPTERS = %w[
    DynamoDbGreetingCounter
    InMemoryGreetingCounter
    SystemClock
    JsonPresenter
    RackApp
    LambdaHandler
  ].freeze

  describe 'only app.rb references concrete adapters' do
    it 'finds no concrete adapter constant referenced outside app.rb' do
      offenders = {}

      ruby_files.each do |path|
        rel = path.sub("#{LIB_DIR}/", '')
        # The composition root is allowed to wire concrete adapters.
        next if rel.end_with?('app.rb')
        # The adapter definitions themselves obviously name their own class.
        next if rel.start_with?('greeter_http/adapters/')

        source = File.read(path)
        hits = CONCRETE_ADAPTERS.select do |const|
          source.match?(/\b#{Regexp.escape(const)}\b/)
        end
        offenders[rel] = hits unless hits.empty?
      end

      expect(offenders).to be_empty,
        "concrete adapters referenced outside app.rb: #{offenders.inspect}"
    end
  end

  describe 'no file reopens a Greeter::Core class' do
    # Matches `module Greeter` / `class Greeter::...` reopenings, and
    # `class X < Greeter::Core::...` subclassing.
    #
    # EXCEPTION: subclassing an abstract port under `Greeter::Core::Ports::` is
    # the gem's sanctioned extension point (those classes ship with methods that
    # raise NotImplementedError specifically to be implemented by adapters), so
    # the subclass pattern excludes `Greeter::Core::Ports::`. Reopening or
    # subclassing any core *domain* class remains forbidden.
    REOPEN_PATTERNS = [
      /^\s*module\s+Greeter\b/,
      /^\s*class\s+Greeter\b/,
      /^\s*(module|class)\s+Greeter::Core\b/,
      /^\s*class\s+\w+\s*<\s*Greeter::Core::(?!Ports::)/
    ].freeze

    it 'finds no reopening or subclassing of Greeter::Core' do
      offenders = {}

      ruby_files.each do |path|
        rel = path.sub("#{LIB_DIR}/", '')
        File.readlines(path).each_with_index do |line, i|
          next if REOPEN_PATTERNS.none? { |re| line.match?(re) }

          (offenders[rel] ||= []) << "#{i + 1}: #{line.strip}"
        end
      end

      expect(offenders).to be_empty,
        "Greeter::Core reopened/subclassed: #{offenders.inspect}"
    end
  end
end
