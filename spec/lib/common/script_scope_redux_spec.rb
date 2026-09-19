# frozen_string_literal: true

require_relative '../../spec_helper'
require_relative '../../../lib/common/script_scope'

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

  it 'keeps a method defined by the script immediately callable' do
    binding = described_class.script_binding
    expect(eval('def scope_redux_helper; 42; end; scope_redux_helper', binding)).to eq(42)
  ensure
    described_class.send(:remove_method, :scope_redux_helper) if described_class.instance_methods(false).include?(:scope_redux_helper)
  end
end
