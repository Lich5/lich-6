#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tempfile'
require 'yaml'

module SecurityCheckRunner
  module_function

  def run(entries, root:, ruby: RbConfig.ruby, output: $stderr)
    entries.to_h do |entry|
      id = entry.fetch('id')
      next [id, 'neutral'] if entry.fetch('state') == 'pending'

      Tempfile.create(['lich-security-check-', '.json']) do |results|
        command = [
          ruby, '-S', 'rspec', entry.fetch('spec'),
          '--tag', "security_id:#{entry.fetch('tag')}", '--format', 'json', '--out', results.path,
        ]
        stdout, stderr, status = Open3.capture3(*command, chdir: root)
        example_count = JSON.parse(File.read(results.path)).dig('summary', 'example_count').to_i
        passed = status.success? && example_count.positive?
        output.puts("#{id}: #{passed ? 'success' : 'failure'} (#{example_count} examples)")
        output.puts(stdout) unless passed || stdout.empty?
        output.puts(stderr) unless passed || stderr.empty?
        [id, passed ? 'success' : 'failure']
      rescue JSON::ParserError, Errno::ENOENT
        output.puts("#{id}: failure (unreadable RSpec results)")
        [id, 'failure']
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('../..', __dir__)
  manifest = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
  results = SecurityCheckRunner.run(manifest.fetch('tests'), root: root)
  File.write(ARGV.fetch(1), JSON.pretty_generate(results) + "\n")
  exit(results.values.all? { |result| %w[success neutral].include?(result) } ? 0 : 1)
end
