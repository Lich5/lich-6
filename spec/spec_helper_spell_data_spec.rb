# frozen_string_literal: true

require_relative 'spec_helper'
require 'open3'
require 'rbconfig'
require 'json'

RSpec.describe 'spell fixture initialization' do
  it 'loads only once across repeated spec initialization without reaching the network' do
    program = <<~'CHILD'
      require 'json'
      require 'open-uri'
      require 'common/spell'
      module NoSpellFixtureNetwork
        # Rejects accidental downloads while initializing committed fixture data.
        # @param args [Array] unused network request arguments
        # @return [void] always raises when a request is attempted
        def open(*args)
          raise 'spell fixture initialization attempted network access'
        end
      end
      URI.singleton_class.prepend(NoSpellFixtureNetwork)
      calls = 0
      original = Lich::Common::Spell.method(:load)
      Lich::Common::Spell.define_singleton_method(:load) do |*args|
        calls += 1
        original.call(*args)
      end
      first = load_spell_data
      second = load_spell_data
      puts JSON.generate(first: first, second: second, calls: calls,
                         loaded: Lich::Common::Spell.class_variable_get(:@@loaded),
                         spells: Lich::Common::Spell.list.length)
    CHILD
    output, error, status = Open3.capture3(RbConfig.ruby, '-r', File.join(SPEC_ROOT, 'spec_helper.rb'), '-e', program)
    expect(status.success?).to be(true), error
    result = JSON.parse(output)
    expect(result).to include('first' => true, 'second' => true, 'calls' => 1, 'loaded' => true)
    expect(result.fetch('spells')).to be > 400
  end
end
