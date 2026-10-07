# frozen_string_literal: true

require 'os'
require 'json'
require_relative 'errors'

module Lich
  module WebUI
    # Selects a bundled native window helper without compiling at runtime.
    # Windows and Linux continue to use the browser launcher.
    module NativeHost
      EXECUTABLE = File.expand_path('native/macos/build/LichWebUI.app/Contents/MacOS/LichWebUI', __dir__).freeze

      module_function

      # @return [Boolean] whether the current OS uses the AppKit host
      def mac? = OS.mac?

      # @param platform [String, nil] explicit test/discovery override
      # @return [Symbol, nil] native host kind, or nil for a browser host
      def platform(platform = nil)
        return :macos if platform ? platform.match?(/darwin/i) : mac?

        nil
      end

      # Builds argv for an isolated native window. Never invokes a shell.
      # @param url [String] authenticated loopback launch URL
      # @param geometry [Hash, nil] initial outer size and desktop position
      # @return [Array<String>] executable and arguments
      # @raise [Error] if the helper has not been built or supplied
      def command_for(url, geometry: nil)
        unless File.executable?(EXECUTABLE)
          raise Error, 'macOS WebUI helper is missing; run lib/webui/native/macos/build.sh or supply the prebuilt helper'
        end

        [EXECUTABLE, url, JSON.generate(geometry || {})]
      end
    end
  end
end
