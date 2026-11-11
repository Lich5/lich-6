# frozen_string_literal: true

# Disposable installer parity receipt; retire with the accepted Windows testbed
# receipt and delete this helper when the testbed branch is retired.
require 'json'
require 'rbconfig'
require_relative '../../lib/accepted_gem_policy'
require_relative '../../lib/runtime_gem_contract'
require_relative '../../lib/version'

receipt_path = ARGV.fetch(0)
receipt = {
  'ruby'         => RUBY_DESCRIPTION,
  'executable'   => RbConfig.ruby,
  'gem_home'     => Gem.dir,
  'gem_path'     => Gem.path,
  'manifest_url' => Lich::DependencyRecovery::DEFAULT_MANIFEST_URL
}

begin
  raise 'preflight requires Windows Ruby 4.0.9' unless Gem.win_platform? && RUBY_VERSION == '4.0.9'
  raise 'preflight must use the default live manifest' if ENV.key?('LICH_GEM_MANIFEST_URL')
  raise 'preflight must run without Bundler activation' if defined?(Bundler) || ENV.key?('BUNDLE_GEMFILE')

  reader = Lich::RuntimeGemContract.new(gemfile: File.binread(File.expand_path('../../Gemfile', __dir__)), groups: ['default'])
  dependencies = reader.roots.map { |name, requirements| Gem::Dependency.new(name, *requirements) }
  policy = Lich::AcceptedGemPolicy.new
  check = policy.check(dependencies)
  receipt['needed'] = check.needed
  raise "installed runtime needs startup recovery: #{check.needed.join(', ')}" unless check.needed.empty?

  policy.activate!(check)
  # Actual native loads and representative startup dependencies supplement the
  # producer's complete smoke. Application acceptance still runs real GemCheck.
  %w[sqlite3 ox ffi os sequel webrick json].each { |name| require name }
  receipt['selected'] = check.specs.map { |spec| { 'name' => spec.name, 'version' => spec.version.to_s, 'platform' => spec.platform.to_s } }
  receipt['status'] = 'passed'
rescue StandardError, LoadError => error # Retain prerequisite failures before propagating them.
  receipt['status'] = 'failed'
  receipt['error'] = "#{error.class}: #{error.message}"
  raise
ensure
  receipt['installed'] = Gem::Specification.map do |spec|
    { 'name' => spec.name, 'version' => spec.version.to_s, 'platform' => spec.platform.to_s, 'path' => spec.full_gem_path }
  end.sort_by { |spec| [spec.fetch('name'), spec.fetch('version')] }
  receipt['loaded'] = Gem.loaded_specs.sort.to_h.transform_values do |spec|
    { 'version' => spec.version.to_s, 'platform' => spec.platform.to_s, 'path' => spec.full_gem_path }
  end
  File.write(receipt_path, JSON.pretty_generate(receipt))
end
