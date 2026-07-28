# frozen_string_literal: true

require 'spec_helper'
require 'common/conformance_harness'
require 'json'
require 'yaml'

RSpec.describe Lich::Common::ConformanceHarness do
  it 'returns a binary pass result for a fixture trace' do
    fixture_dir = File.join(FIXTURE_DIR, 'conformance')
    manifest = YAML.safe_load_file(File.join(fixture_dir, 'manifest.yml'), aliases: false)
    fixture_entry = manifest.fetch('fixtures').fetch(0)
    fixture = JSON.parse(File.read(File.join(fixture_dir, fixture_entry.fetch('path'))))

    expect(fixture_entry).to include('origin', 'license')
    expect(described_class.new.evaluate(script_id: fixture.fetch('script_id'), trace: fixture.fetch('trace'))).to eq(
      { 'script_id' => 'ci-foundation-fixture.lic', 'verdict' => 'pass' }
    )
  end

  it 'rejects invalid caller input' do
    expect { described_class.new.evaluate(script_id: '', trace: []) }.to raise_error(ArgumentError)
    expect { described_class.new.evaluate(script_id: 'fixture.lic', trace: nil) }.to raise_error(ArgumentError)
    expect { described_class.new.evaluate(script_id: 'fixture.lic', trace: ['Gtk::Window.new']) }.to raise_error(ArgumentError)
  end

  it 'returns a categorized binary failure result' do
    result = described_class.new.evaluate(
      script_id: 'fixture.lic', trace: [], failure_category: 'security_refusal'
    )
    expect(result).to eq(
      { 'script_id' => 'fixture.lic', 'verdict' => 'fail', 'failure_category' => 'security_refusal' }
    )
  end
end
