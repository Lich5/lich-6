# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webui'

RSpec.describe Lich::WebUI::WindowPresentation::Controller do
  let(:win32) do
    Class.new do
      attr_accessor :windows, :fail_position
      attr_reader :positions, :alphas, :styles

      def initialize
        @windows = [[0x1_0000_0050, 42], [90, 99]]
        @positions, @alphas, @styles = [], [], Hash.new(0x80)
      end

      def EnumWindows(callback, _context)
        windows.each { |hwnd, _| callback.call(Fiddle::Pointer.new(hwnd), 0) }
        1
      end

      def IsWindow(hwnd) = windows.any? { |row| row.first == hwnd.to_i } ? 1 : 0
      def IsWindowVisible(_hwnd) = 1
      def GetWindow(*) = Fiddle::Pointer.new(0)

      def GetWindowThreadProcessId(hwnd, buffer)
        buffer.replace([windows.find { |row| row.first == hwnd.to_i }.last].pack('L'))
        1
      end

      def GetClassNameW(_hwnd, buffer, _length)
        name = 'Chrome_WidgetWin_1'.encode('UTF-16LE')
        buffer[0, name.bytesize] = name
        name.bytesize / 2
      end

      def SetWindowPos(hwnd, target, *arguments)
        @positions << [hwnd.to_i, target, arguments]
        fail_position ? 0 : 1
      end

      def GetWindowLongW(hwnd, _index) = styles[hwnd.to_i]

      def SetWindowLongW(hwnd, _index, value)
        previous = styles[hwnd.to_i]
        styles[hwnd.to_i] = value
        previous
      end

      def SetLastError(*) = nil
      def GetLastError = 0

      def SetLayeredWindowAttributes(hwnd, _color, alpha, flags)
        @alphas << [hwnd.to_i, alpha, flags]
        1
      end
    end.new
  end
  let(:workers) { [] }
  let(:clock) { [0.0] }
  let(:controller) do
    described_class.new(win32: win32, thread_factory: ->(&work) { workers << work },
                        sleeper: ->(*) { clock[0] += 16 }, clock: -> { clock[0] })
  end

  def render(generation, page: {}, facility: {})
    tree = Struct.new(:props).new({ presentation: page })
    Struct.new(:generation, :tree, :facilities).new(generation, tree, { presentation: facility })
  end

  it 'sets a pointer-sized topmost handle without taking focus and applies real window alpha' do
    controller.update(render(1, facility: { always_on_top: true, opacity: 0.5 }))
    controller.start(42)
    workers.shift.call
    hwnd, target, arguments = win32.positions.fetch(0)
    expect(hwnd).to eq(0x1_0000_0050)
    expect(target).to be_a(Fiddle::Pointer)
    expect(target.to_i).to eq(Fiddle::Pointer.new(-1).to_i)
    expect(arguments).to eq([0, 0, 0, 0, 0x13])
    expect(win32.alphas).to eq([[hwnd, 128, 2]])
    expect(win32.styles[hwnd]).to eq(0x80080)

    controller.update(render(2))
    expect(win32.positions.last[1].to_i).to eq(Fiddle::Pointer.new(-2).to_i)
    expect(win32.alphas.last).to eq([hwnd, 255, 2])
    expect(win32.styles[hwnd]).to eq(0x80080)
  end

  it 'uses the latest native/shim request during discovery and ignores delayed older renders' do
    controller.update(render(1, page: { always_on_top: true, opacity: 0.3 }))
    controller.start(42)
    controller.update(render(3, page: { opacity: 0.4 }, facility: { opacity: 0.8 }))
    workers.shift.call
    controller.update(render(2, facility: { opacity: 0.2 }))
    expect(win32.alphas.map { |row| row[1] }).to eq([204])
  end

  it 'refuses a foreign browser and ambiguous windows instead of falling back to their titles' do
    [[[90, 99]], [[80, 42], [81, 42]]].each do |windows|
      win32.windows = windows
      instance = described_class.new(win32: win32, thread_factory: ->(&work) { work.call },
                                     sleeper: ->(*) { clock[0] += 16 }, clock: -> { clock[0] })
      instance.start(42)
      expect(win32.positions).to be_empty
    end
  end

  it 'cancels discovery and subsequent renders when the owner closes' do
    controller.start(42)
    controller.close
    workers.shift.call
    controller.update(render(2, facility: { opacity: 0.3 }))
    expect(win32.positions).to be_empty
  end

  it 'rechecks handle ownership before updating an already discovered window' do
    controller.start(42)
    workers.shift.call
    win32.windows[0][1] = 99
    controller.update(render(2, facility: { opacity: 0.3 }))
    expect(win32.positions.length).to eq(1)
  end

  it 'reports native failures instead of treating them as successful presentation' do
    win32.fail_position = true
    expect(Lich::WebUI::WindowPresentation).to receive(:warn_failure).with(an_instance_of(Lich::WebUI::Error))
    controller.start(42)
    workers.shift.call
    expect(win32.alphas).to be_empty
  end
end
