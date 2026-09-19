# frozen_string_literal: true

# Reconciles exact frozen sources with execution evidence. Unmeasured rows remain
# explicit; this generator never substitutes a source grep for a runtime trace.
require 'json'
require 'digest'
require 'date'

corpus = ARGV.fetch(0)
corrected_root = ARGV[1]
root = File.expand_path('../..', __dir__)
commits = {
  'eo-scripts' => 'c7cc983beedf3a43b6f743ac3d595cfc679bee8f',
  'dr-scripts' => '159abc89be732bea27e8673a2f99a0994f1f4c4a'
}.freeze
population = {
  'eo-scripts' => %w[ForgeMaster MyFletch alias armor betazzherb boon clearcheckwiz ecure eforgery fletchit hands_and_room heal_spellup iSigns isigils localchat madwarrior mybounty perfume sbounty sellunder signore sloot spellson symbolz uberfletch vars],
  'dr-scripts' => %w[kill-counter performance-monitor status-monitor]
}.freeze

rows = population.flat_map do |repository, names|
  names.map do |name|
    source_path = repository == 'eo-scripts' ? "scripts/#{name}.lic" : "#{name}.lic"
    source_hash = Digest::SHA256.file(File.join(corpus, repository, source_path)).hexdigest
    artifact = "docs/webui-redux/r4-traces/#{name}.json"
    trace_path = File.join(root, artifact)
    evidence = File.exist?(trace_path) ? JSON.parse(File.read(trace_path)) : nil
    if evidence && (evidence.fetch('sha256') != source_hash || evidence.fetch('source_path') != source_path)
      abort "source provenance mismatch for #{repository}/#{source_path}"
    end
    trace = evidence ? evidence.fetch('trace') : []
    calls = trace.select { |event| event['phase'] == 'call' }
    corrected_artifact = "docs/webui-redux/r4-corrected-traces/#{name}.json"
    corrected_path = File.join(root, corrected_artifact)
    corrected = if corrected_root && repository == 'eo-scripts' && File.exist?(corrected_path)
                  JSON.parse(File.read(corrected_path))
                end
    if corrected
      current_hash = Digest::SHA256.file(File.join(corrected_root, source_path)).hexdigest
      abort "corrected source provenance mismatch for #{name}" unless corrected.fetch('sha256') == current_hash && corrected.fetch('source_path') == source_path
    end
    {
      id: name, repository: repository, repository_commit: commits.fetch(repository),
      source_path: source_path, sha256: source_hash,
      entrypoint: evidence ? evidence.fetch('entrypoint') : 'UNMEASURED',
      gate: trace.select { |event| event['phase'] == 'gate' },
      classes: calls.select { |event| event['operation'] == 'initialize' }.map { |event| event.fetch('receiver') }.uniq.sort,
      operations: calls.map { |event| event.slice('receiver', 'operation', 'source', 'line', 'signal') }.uniq,
      chain_sites: trace.select { |event| event['phase'] == 'return' && event['returns_self'] }.map { |event| event.slice('receiver', 'operation', 'source', 'line') }.uniq,
      expected_controls: evidence ? evidence.fetch('expected_controls') : [],
      trace_artifact: evidence ? artifact : nil,
      automated_result: {
        status: evidence ? (evidence.fetch('browser') ? 'BROWSER_PATH_VERIFIED' : 'RUNTIME_PATH_VERIFIED') : 'UNMEASURED',
        check: evidence && evidence.fetch('command')
      },
      corrected_source: corrected && {
        sha256: corrected.fetch('sha256'), source_path: source_path,
        entrypoint: corrected.fetch('entrypoint'), trace_artifact: corrected_artifact,
        status: corrected.fetch('browser') ? 'BROWSER_PATH_VERIFIED' : 'RUNTIME_PATH_VERIFIED',
        check: corrected.fetch('command'),
        classes: corrected.fetch('trace').select { |event| event['phase'] == 'call' && event['operation'] == 'initialize' }.map { |event| event.fetch('receiver') }.uniq.sort
      },
      human_result: 'PENDING'
    }
  end
end

output = {
  schema_version: '1.1.0', status: 'IN_PROGRESS', generated_date: Date.today.iso8601,
  generation_command: 'ruby script/support/r4_population.rb "$R4_CORPUS_ROOT" "$R4_SOURCE_REPO"',
  generation_ruby: RUBY_DESCRIPTION, repository_commits: commits,
  accepted_script_count: 29, accepted_class_bound: 28, script_count: rows.length,
  measured_class_count: rows.flat_map { |row| row[:classes] }.uniq.length,
  current_measured_class_count: rows.flat_map { |row| row[:corrected_source] ? row[:corrected_source][:classes] : row[:classes] }.uniq.length,
  current_browser_path_count: rows.count { |row| (row[:corrected_source] || row[:automated_result])[:status] == 'BROWSER_PATH_VERIFIED' },
  note: 'Owner accepted the 29-script population. Unmeasured rows and known source defects do not count as completed consumer proof.',
  rows: rows
}
abort 'population changed' unless rows.length == 29 && rows.map { |row| [row[:repository], row[:source_path]] }.uniq.length == 29
File.write(File.join(root, 'docs/webui-redux/r4-shim-population.json'), JSON.pretty_generate(output) + "\n")
puts "29 source hashes reconciled; #{rows.count { |row| row[:trace_artifact] }} execution traces present"
