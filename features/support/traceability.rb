# frozen_string_literal: true

# Copied from greeter-cli/features/support/traceability.rb.
#
# Records every executed scenario (name, tags, status) to tmp/traceability.json
# so the acceptance run can be diffed against the OpenSpec change:
#
#   openspec show add-greeting-counter-http --json
#
# Each @requirement-greeting-counter scenario should correspond to exactly one
# scenario in the greeting-counter spec delta.

require 'json'
require 'fileutils'

TRACEABILITY_PATH = File.join(__dir__, '..', '..', 'tmp', 'traceability.json')

After do |scenario|
  FileUtils.mkdir_p(File.dirname(TRACEABILITY_PATH))

  existing = if File.exist?(TRACEABILITY_PATH)
               JSON.parse(File.read(TRACEABILITY_PATH))
             else
               []
             end

  existing << {
    'scenario' => scenario.name,
    'tags' => scenario.tags.map(&:name),
    'status' => scenario.status.to_s
  }

  File.write(TRACEABILITY_PATH, JSON.pretty_generate(existing))
end
