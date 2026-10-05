# frozen_string_literal: true

require_relative 'file_service'
require_relative 'browser_window'
require_relative 'modal_coordinator'
require_relative 'registry'
require_relative 'runtime'
require_relative 'server'
require_relative 'window_geometry_store'

module Lich
  module WebUI
    # Composes the contract registry, runtime, file boundary, and loopback server.
    class Service
      ASSETS_DIR = File.expand_path('assets', __dir__).freeze

      attr_reader :registry, :runtime, :file_service, :server, :modals

      def initialize(registry: Registry.new, application_roots: [ASSETS_DIR], user_allowlist: [],
                     host: '127.0.0.1', port: 0, logger: nil, browser_open: nil, browser_terminate: Process.method(:kill), geometry_store: nil)
        @registry = registry
        @stopped = false
        @windows = {}.compare_by_identity
        @windows_mutex = Mutex.new
        @browser_open = browser_open
        @browser_terminate = browser_terminate
        @geometry_store = geometry_store
        @logger = logger || proc { |level, message| Lich.log("#{level}: #{message}") if Lich.respond_to?(:log) }
        @file_service = FileService.new(
          application_roots: application_roots, user_allowlist: user_allowlist, logger: @logger
        )
        @runtime = Runtime.new(
          registry: registry, file_service: file_service, logger: @logger,
          on_page_closed: method(:close_window)
        )
        @server = Server.new(
          assets_dir: ASSETS_DIR, pages_provider: -> { registry.descriptors },
          message_handler: ->(connection, message) { runtime.handle(connection, message) },
          disconnect_handler: ->(connection) { runtime.disconnect(connection) },
          file_service: file_service, host: host, port: port, logger: @logger
        )
        @modals = ModalCoordinator.new(
          registry: registry, runtime: runtime, viewers_present: ->(owner) { runtime.viewers_present?(owner) },
          pages_changed: -> { server.broadcast(type: 'pages', pages: registry.descriptors) }, logger: @logger
        )
      end

      def start
        raise Error, 'stopped services cannot be restarted; create a fresh service' if @stopped

        server.start
        self
      end

      def stop
        @windows_mutex.synchronize { @windows.keys.dup }.each { |page| save_geometry(page) }
        windows = @windows_mutex.synchronize do
          @stopped = true
          current = @windows.values
          @windows.clear
          current
        end
        windows.each(&:close)
        server.stop
        runtime.shutdown
        self
      end

      def stopped? = @stopped

      def launch_url(page: nil)
        target = page ? "/?page=#{registry.address_for(page)}" : '/'
        server.launch_url(to: target)
      end

      # Window ownership belongs to the host, for native and compatibility pages.
      # Reserve before spawning so repeated opens and concurrent shutdown agree.
      def open(page, geometry: nil)
        # Explicit caller geometry and script configure handlers retain their
        # existing settings authority. Otherwise saved user geometry precedes
        # a page's default size (for example a setup form's first-run size).
        props = page.last_render&.tree&.props
        geometry ||= @geometry_store&.read(page) unless page.lifecycle_bindings.key?(:configure)
        if geometry.nil? && props && props[:size]
          geometry = { width: props[:size][0], height: props[:size][1], position: props[:position] }
        end
        page.restore_window_geometry(geometry) if geometry
        url = launch_url(page: page)
        window = @windows_mutex.synchronize do
          raise Error, 'service is stopped' if @stopped
          return true if @windows.key?(page)
          registry.address_for(page)
          runtime.watch_window(page)

          @windows[page] = BrowserWindow.new(
            opener: @browser_open, terminate: @browser_terminate,
            on_close: -> { browser_closed(page) }
          )
        end
        # Spawn and monitor setup must survive the requesting script's exit.
        result = HostThread.start { window.open(url, geometry: geometry) }.value
        close_window(page) unless result
        result
      rescue StandardError
        close_window(page) if window
        raise
      end

      def close_window(page)
        save_geometry(page)
        window = @windows_mutex.synchronize { @windows.delete(page) }
        window&.close
      end

      def browser_closed(page)
        save_geometry(page)
        window = @windows_mutex.synchronize { @windows.delete(page) }
        runtime.browser_closed(page) if window
      end

      def refresh(page)
        runtime.refresh(page)
      end

      def terminate_owner(owner)
        modals.terminate_owner(owner)
        file_service.revoke_owner(owner)
        runtime.terminate_owner(owner)
      end

      def modal(**options, &content)
        modals.open(**options, &content)
      end

      def register_files(alias_name, directory, owner:, script_root: nil)
        file_service.register(alias_name, directory, owner: owner, script_root: script_root)
      end

      # A persistence failure must not leave the browser process or script alive.
      def save_geometry(page)
        @geometry_store&.save(page)
      rescue StandardError => error
        @logger.call(:warning, "WebUI geometry save failed: #{error.class}")
      end
    end
  end
end
