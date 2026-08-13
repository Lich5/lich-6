#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'yaml'

module SecurityCheckRunner
  module_function

  def run(entries, root:, ruby: RbConfig.ruby, output: $stderr)
    entries.to_h do |entry|
      id = entry.fetch('id')
      next [id, 'neutral'] if entry.fetch('state') == 'pending'

      command = [
        ruby, '-S', 'rspec', entry.fetch('spec'),
        '--tag', "security_id:#{entry.fetch('tag')}", '--format', 'progress',
      ]
      stdout, stderr, status = Open3.capture3(*command, chdir: root)
      output.puts("#{id}: #{status.success? ? 'success' : 'failure'}")
      output.puts(stdout) unless status.success? || stdout.empty?
      output.puts(stderr) unless status.success? || stderr.empty?
      [id, status.success? ? 'success' : 'failure']
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
