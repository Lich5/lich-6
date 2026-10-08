# frozen_string_literal: true

require_relative '../../spec_helper'
require_relative '../../../lib/common/script_scope'
require 'open3'

RSpec.describe Lich::Common::ScriptScope do
  it 'isolates locals, including file, between fresh script bindings' do
    first = described_class.script_binding
    second = described_class.script_binding
    eval('file = :first; local_value = 1', first)

    expect(second.local_variable_defined?(:file)).to be(false)
    expect(second.local_variable_defined?(:local_value)).to be(false)
  end

  it 'resolves core constants without importing class methods into the script' do
    stub_const('Lich::Common::ScopeCoreExample', Class.new do
      def self.class_only = :class_method
    end)
    binding = described_class.script_binding

    expect(eval('ScopeCoreExample.class_only', binding)).to eq(:class_method)
    expect { eval('class_only', binding) }.to raise_error(NameError)
  end

  it 'forwards only declared helpers to inherited script instances' do
    described_class.activate!
    instances = eval(<<~RUBY, described_class.script_binding)
      def scope_runtime_helper; :helper; end
      ScopeRuntimeStruct = Struct.new(:value)
      ScopeRuntimeData = Data.define(:value)
      class ScopeRuntimeError < StandardError; end
      [ScopeRuntimeStruct.new(1), ScopeRuntimeData.new(1), ScopeRuntimeError.new]
    RUBY
    instances.each do |instance|
      expect(instance.scope_runtime_helper).to eq(:helper)
      expect(instance.respond_to?(:scope_runtime_helper)).to be(true)
      expect(instance.respond_to?(:const_get)).to be(false)
      expect(instance.respond_to?(:name)).to be(false)
      expect { instance.const_get(:Gtk) }.to raise_error(NoMethodError)
    end
  ensure
    %i[ScopeRuntimeStruct ScopeRuntimeData ScopeRuntimeError].each do |name|
      described_class.send(:remove_const, name) if described_class.const_defined?(name, false)
    end
    described_class.send(:remove_method, :scope_runtime_helper) if described_class.instance_methods(false).include?(:scope_runtime_helper)
  end

  it 'does not mutate Comparable or core classes through a script constant alias' do
    source = <<~RUBY
      scope = Lich::Common::ScriptScope
      scope.activate!
      ancestors = [Comparable, String, Integer].map(&:ancestors)
      eval('def scope_alias_probe; :leaked; end; RuntimeComparable = ::Comparable', scope.script_binding)
      abort 'core ancestors changed' unless [Comparable, String, Integer].map(&:ancestors) == ancestors
      abort 'helper leaked into core' if ''.respond_to?(:scope_alias_probe) || 1.respond_to?(:scope_alias_probe)
    RUBY
    # A regression must not contaminate the parent suite's core ancestors.
    output, status = Open3.capture2e(RbConfig.ruby, '-I', File.expand_path('../../../lib', __dir__),
                                     '-rcommon/script_scope', '-e', source)
    expect(status.success?).to be(true), output
  end

  it 'keeps newly defined nested script classes connected to their helpers' do
    described_class.activate!
    result = eval(<<~RUBY, described_class.script_binding)
      def scope_nested_probe; :available; end
      module RuntimeNamespace
        class Leaf
          def probe; scope_nested_probe; end
        end
      end
      RuntimeNamespace::Leaf.new.probe
    RUBY
    expect(result).to eq(:available)
  ensure
    described_class.send(:remove_const, :RuntimeNamespace) if described_class.const_defined?(:RuntimeNamespace, false)
    described_class.send(:remove_method, :scope_nested_probe) if described_class.instance_methods(false).include?(:scope_nested_probe)
  end

  it 'keeps a method defined by the script immediately callable' do
    binding = described_class.script_binding
    expect(eval('def scope_redux_helper; 42; end; scope_redux_helper', binding)).to eq(42)
  ensure
    described_class.send(:remove_method, :scope_redux_helper) if described_class.instance_methods(false).include?(:scope_redux_helper)
  end
end
