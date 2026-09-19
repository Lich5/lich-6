# frozen_string_literal: true

require_relative '../../../spec_helper'
require 'gemstone/combat/async_processor'

# Preserve ordered 5.21.0 combat processing alongside R3's native Ruby
# compaction. No GUI runtime participates in this worker's lifecycle.
RSpec.describe Lich::Gemstone::Combat::AsyncProcessor do
  before do
    stub_const('Lich::Gemstone::Combat::Tracker', Module.new)
    allow(Lich::Gemstone::Combat::Tracker).to receive(:debug?).and_return(false)
    stub_const('Lich::Gemstone::Combat::Processor', Module.new)
    allow(Lich::Gemstone::Combat::Processor).to receive(:process)
  end

  def quiet_gc
    allow(GC).to receive(:start)
    allow(GC).to receive(:compact)
  end

  describe '#process_async' do
    it 'processes chunks in arrival order on the worker thread' do
      seen = []
      allow(Lich::Gemstone::Combat::Processor).to receive(:process) { |chunk| seen << chunk.first }
      quiet_gc

      processor = described_class.new
      processor.process_async(['one'])
      processor.process_async(['two'])
      processor.process_async(['three'])
      processor.shutdown

      expect(seen).to eq(%w[one two three])
    end

    it 'ignores empty chunks' do
      quiet_gc
      processor = described_class.new
      processor.process_async([])
      processor.shutdown

      expect(Lich::Gemstone::Combat::Processor).not_to have_received(:process)
    end

    it 'survives a Processor error and keeps processing later chunks' do
      seen = []
      allow(Lich::Gemstone::Combat::Processor).to receive(:process) do |chunk|
        raise 'boom' if chunk.first == 'bad'
        seen << chunk.first
      end
      quiet_gc

      processor = described_class.new
      processor.process_async(['bad'])
      processor.process_async(['good'])
      processor.shutdown

      expect(seen).to eq(['good'])
    end
  end

  describe '#shutdown' do
    it 'drains queued chunks before the worker exits' do
      processed = 0
      allow(Lich::Gemstone::Combat::Processor).to receive(:process) { processed += 1 }
      quiet_gc

      processor = described_class.new
      5.times { processor.process_async(['line']) }
      processor.shutdown

      expect(processed).to eq(5)
    end

    it 'stops the worker thread' do
      quiet_gc
      processor = described_class.new
      processor.shutdown

      expect(processor.stats[:worker_alive]).to be false
    end

    it 'calls GC.start with no arguments' do
      quiet_gc
      processor = described_class.new
      processor.shutdown

      expect(GC).to have_received(:start).with(no_args)
    end

    it 'compacts the Ruby heap after draining work' do
      quiet_gc
      processor = described_class.new
      processor.shutdown

      expect(GC).to have_received(:compact)
    end

    it 'does not raise when Tracker.debug? is true (debug logging does not interfere)' do
      allow(Lich::Gemstone::Combat::Tracker).to receive(:debug?).and_return(true)
      quiet_gc
      processor = described_class.new

      expect { processor.shutdown }.not_to raise_error
      expect(GC).to have_received(:compact)
    end
  end

  describe '#stats' do
    it 'reports queue and processing counters' do
      quiet_gc
      processor = described_class.new
      processor.process_async(['line'])
      processor.shutdown

      stats = processor.stats
      expect(stats[:total]).to eq(1)
      expect(stats[:queued]).to eq(0)
      expect(stats[:active]).to eq(0)
    end
  end
end
