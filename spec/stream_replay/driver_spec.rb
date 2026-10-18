# frozen_string_literal: true

require_relative '../spec_helper'
require 'tempfile'
require_relative '../support/stream_replay/fixture'
require_relative '../support/stream_replay/driver'

# Driver#snapshot_count is polled every few ms while a replay waits for the
# probe; it must count only complete snapshot lines after the ready marker and
# read only what was appended since the previous poll.
RSpec.describe StreamReplay::Driver do
  let(:driver) { described_class.new(StreamReplay::Fixture.new('x.xml', "### stream-replay:body-below ###\n")) }
  let(:file) { Tempfile.new(['snapshots', '.jsonl']) }

  before do
    driver.instance_variable_set(:@snapshot_bytes, 0)
    driver.instance_variable_set(:@snapshot_lines, 0)
  end

  after { file.close! }

  # Appends text to the snapshot-count test file.
  # @param text [String] text to parse or append
  # @return [void] appends and flushes the snapshot fixture
  def append(text)
    file.write(text)
    file.flush
  end

  # Queries the replay driver snapshot counter.
  # @return [Integer] the number of complete snapshots excluding readiness
  def count
    driver.send(:snapshot_count, file.path)
  end

  it 'uses the parent Ruby and installed gems without invoking Bundler' do
    args = driver.send(:child_args, '/tmp/replay', 4000)
    expect(args.first).to eq(RbConfig.ruby)
    expect(args).not_to include('bundle', 'exec')
    expect(driver.send(:child_env, '/tmp/snapshots')).to eq('LICH_REPLAY_SNAPSHOTS' => '/tmp/snapshots')
  end

  it 'is 0 before the probe has written anything' do
    expect(driver.send(:snapshot_count, "#{file.path}.missing")).to eq(0)
  end

  it 'does not count the ready marker as a snapshot' do
    append(%({"ready":true}\n))
    expect(count).to eq(0)
  end

  it 'counts snapshots appended between polls' do
    append(%({"ready":true}\n{"prompt":1}\n))
    expect(count).to eq(1)
    append(%({"prompt":2}\n{"prompt":3}\n))
    expect(count).to eq(3)
    expect(count).to eq(3)
  end

  it 'counts a snapshot only once its line is complete' do
    append(%({"ready":true}\n{"prompt":1}\n{"prom))
    expect(count).to eq(1)
    append(%(pt":2}\n))
    expect(count).to eq(2)
  end

  it 'counts the same as a full re-read after many polls' do
    append(%({"ready":true}\n))
    50.times do |i|
      append(%({"prompt":#{i + 1},"pad":"#{'x' * (i * 37)}"}\n))
      count
    end
    expect(count).to eq(File.foreach(file.path).count - 1)
  end
end
