#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

expected = %w[REQ-SEC-012 REQ-SEC-013 REQ-SEC-020 REQ-SEC-031 REQ-SEC-034 REQ-SEC-070 REQ-SEC-071 REQ-SEC-072 REQ-SEC-073 REQ-SEC-077].freeze
manifest = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
entries = manifest.fetch('tests')
abort 'security manifest must have exactly ten entries' unless entries.length == expected.length
requirements = entries.map { |entry| entry.fetch('requirement') }
abort 'security manifest requirements do not match SPEC-WEBUI-SECURITY v1.1.1' unless requirements.sort == expected.sort
entries.each do |entry|
  %w[id requirement check_name state].each { |key| abort "missing #{key}" unless entry[key].is_a?(String) && !entry[key].empty? }
  abort "invalid state for #{entry['id']}" unless %w[pending implemented].include?(entry['state'])
  next unless entry['state'] == 'implemented'

  %w[spec tag].each { |key| abort "implemented #{entry['id']} is missing #{key}" unless entry[key].is_a?(String) && !entry[key].empty? }
  abort "implemented #{entry['id']} must use its stable id as the RSpec tag" unless entry['tag'] == entry['id']
  root = File.expand_path('../..', __dir__)
  spec_path = File.expand_path(entry['spec'], root)
  abort "implemented #{entry['id']} spec is outside the repository" unless spec_path.start_with?("#{root}/")
  abort "implemented #{entry['id']} spec does not exist" unless File.file?(spec_path)
  source = File.read(spec_path)
  abort "implemented #{entry['id']} spec has no matching security_id tag" unless source.include?("security_id: '#{entry['tag']}'")
end
abort 'security manifest ids must be unique' unless entries.map { |entry| entry['id'] }.uniq.length == entries.length
abort 'security manifest check names must be unique' unless entries.map { |entry| entry['check_name'] }.uniq.length == entries.length

leakage = entries.find { |entry| entry['id'] == 'sec-bulk-leakage' }
method = leakage&.fetch('method', nil)
abort 'bulk leakage entry must define a structured canary method' unless method.is_a?(Hash)
abort 'bulk leakage entry must require a unique high-entropy canary' unless method['canary'] == 'unique high-entropy value'
abort 'bulk leakage entry must define full and fragment checks' unless method['fragments'] == %w[full first-8 last-8]
expected_sinks = ['bulk state payload', 'log line', 'telemetry record', 'error output']
abort 'bulk leakage entry must define all four sinks' unless method['sinks'] == expected_sinks
