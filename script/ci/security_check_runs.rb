#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'

module SecurityCheckRuns
  TOOLCHAINS = %w[without-gtk3 with-gtk3].freeze
  STATES = %w[pending implemented].freeze
  IMPLEMENTED_CONCLUSIONS = %w[success failure].freeze

  def self.build(entries, results: {})
    ids = entries.map { |entry| entry.fetch('id') }
    names = entries.map { |entry| entry.fetch('check_name') }
    raise ArgumentError, 'duplicate id' unless ids.uniq.length == ids.length
    raise ArgumentError, 'duplicate check name' unless names.uniq.length == names.length
    entries.flat_map do |entry|
      state = entry.fetch('state')
      raise ArgumentError, "invalid state: #{state.inspect}" unless STATES.include?(state)

      conclusion = if state == 'pending'
                     'neutral'
                   else
                     results.fetch(entry.fetch('id')).tap do |result|
                       unless IMPLEMENTED_CONCLUSIONS.include?(result)
                         raise ArgumentError, "invalid implemented conclusion: #{result.inspect}"
                       end
                     end
                   end
      TOOLCHAINS.map do |toolchain|
        { 'name' => "#{entry.fetch('check_name')} (#{toolchain})", 'conclusion' => conclusion }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  entries = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false).fetch('tests')
  payloads = SecurityCheckRuns.build(entries)
  abort 'expected twenty unique check runs' unless payloads.length == 20 && payloads.map { |payload| payload['name'] }.uniq.length == 20
  puts JSON.generate(payloads)
end
