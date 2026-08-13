# frozen_string_literal: true

require_relative '../../../spec_helper'
require 'gemstone/combat/async_processor'

RSpec.describe Lich::Gemstone::Combat::AsyncProcessor do
  before do
    stub_const('Lich::Gemstone::Combat::Tracker', Module.new)
    allow(Lich::Gemstone::Combat::Tracker).to receive(:debug?).and_return(false)
  end

  describe '#shutdown' do
    it 'joins workers, collects garbage, and compacts when supported' do
      processor = described_class.new
      thread = instance_double(Thread, alive?: false, join: true)
      processor.instance_variable_set(:@thread_pool, [thread])
      allow(GC).to receive(:start)
      allow(GC).to receive(:respond_to?).and_call_original
      allow(GC).to receive(:respond_to?).with(:compact).and_return(true)
      allow(GC).to receive(:compact)

      processor.shutdown

      expect(thread).to have_received(:join)
      expect(processor.instance_variable_get(:@thread_pool)).to be_empty
      expect(GC).to have_received(:start).with(no_args)
      expect(GC).to have_received(:compact)
    end
  end

  describe '#cleanup_dead_threads' do
    it 'compacts only after the hourly interval when supported' do
      processor = described_class.new
      processor.instance_variable_set(:@last_compact, Time.now - 3601)
      allow(GC).to receive(:start)
      allow(GC).to receive(:respond_to?).and_call_original
      allow(GC).to receive(:respond_to?).with(:compact).and_return(true)
      allow(GC).to receive(:compact)

      processor.send(:cleanup_dead_threads)

      expect(GC).to have_received(:start)
      expect(GC).to have_received(:compact)
    end

    it 'does not compact before the hourly interval' do
      processor = described_class.new
      processor.instance_variable_set(:@last_compact, Time.now)
      allow(GC).to receive(:respond_to?).and_call_original
      allow(GC).to receive(:respond_to?).with(:compact).and_return(true)
      allow(GC).to receive(:compact)

      processor.send(:cleanup_dead_threads)

      expect(GC).not_to have_received(:compact)
    end
  end
end
