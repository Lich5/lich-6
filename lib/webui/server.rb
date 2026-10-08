# frozen_string_literal: true

require_relative 'host_thread'

require 'digest/sha1'
require 'securerandom'
require 'socket'
require 'uri'
require 'cgi/escape'
require_relative 'file_service'
require_relative 'protocol'
require_relative 'websocket'

module Lich
  module WebUI
    # Authenticated loopback-only HTTP/WebSocket service for native WebUI pages.
    class Server
      COOKIE_NAME = 'lich_webui'
      MAX_HEADER_BYTES = 8192
      MAX_CLIENTS = 64
      READ_TIMEOUT = 5
      WS_POLL_INTERVAL = 0.25
      LAUNCH_TOKEN_LIFETIME = 60
      CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; " \
            "connect-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'none'; " \
            "form-action 'self'; frame-ancestors 'none'"
      ASSET_ROUTES = {
        '/'               => ['index.html', 'text/html; charset=utf-8'],
        '/assets/app.js'  => ['app.js', 'text/javascript; charset=utf-8'],
        '/assets/app.css' => ['app.css', 'text/css; charset=utf-8'],
      }.freeze
      LOOPBACK_HOSTS = %w[127.0.0.1 ::1].freeze

      attr_reader :host, :port

      # Builds an inactive, bounded loopback listener with fresh authentication.
      # @param assets_dir [String] existing directory containing renderer assets
      # @param pages_provider [#call] returns currently registered page descriptors
      # @param message_handler [#call] handles a connection and decoded message
      # @param disconnect_handler [#call, nil] releases disconnected viewer state
      # @param file_service [FileService, nil] authenticated image route resolver
      # @param host [String] permitted loopback bind address
      # @param port [Integer] listener port, or zero for an ephemeral port
      # @param logger [#call, nil] receives a level and sanitized diagnostic
      # @param server_factory [#call, nil] listener factory accepting host and port
      # @param thread_factory [#call, nil] creates host-owned accept/client workers
      def initialize(assets_dir:, pages_provider:, message_handler:, disconnect_handler: nil, file_service: nil,
                     host: '127.0.0.1', port: 0, logger: nil,
                     server_factory: nil, thread_factory: nil)
        raise ArgumentError, "WebUI host must be loopback, got #{host.inspect}" unless LOOPBACK_HOSTS.include?(host)
        raise ArgumentError, 'port must be an Integer from 0 through 65535' unless port.is_a?(Integer) && port.between?(0, 65_535)
        raise ArgumentError, 'pages_provider must respond to call' unless pages_provider.respond_to?(:call)
        raise ArgumentError, 'message_handler must respond to call' unless message_handler.respond_to?(:call)
        if disconnect_handler && !disconnect_handler.respond_to?(:call)
          raise ArgumentError, 'disconnect_handler must respond to call'
        end
        raise ArgumentError, 'assets_dir must be a directory' unless File.directory?(assets_dir)

        @host = host
        @port = port
        @assets_dir = File.realpath(assets_dir)
        @pages_provider = pages_provider
        @message_handler = message_handler
        @disconnect_handler = disconnect_handler
        @file_service = file_service
        @logger = logger || proc { |_level, _message| }
        @server_factory = server_factory || ->(bind_host, bind_port) { TCPServer.new(bind_host, bind_port) }
        @thread_factory = thread_factory || HostThread.method(:start)
        @session_token = SecureRandom.hex(32)
        @launch_tokens = {}
        @server = nil
        @accept_thread = nil
        @client_threads = []
        @client_sockets = []
        @connections = []
        @mutex = Mutex.new
        @stopping = false
      end

      # Starts or repairs the accept worker while retaining a usable loopback listener.
      # Startup failures stop owned resources before propagating the error.
      # @return [Server] self
      # @raise [Error] if the bound listener is not loopback
      def start
        @mutex.synchronize do
          return self if running_locked?

          @stopping = false
          # If the accept worker failed, reuse its live listener. Rebinding the
          # still-owned port both fails and needlessly disconnects other pages.
          @server = nil if @server&.closed?
          @server ||= @server_factory.call(host, port)
          bound = @server.addr
          unless loopback_address?(bound[3])
            @server.close
            @server = nil
            raise Error, "WebUI listener resolved outside loopback: #{bound[3]}"
          end
          @port = bound[1]
          @accept_thread = @thread_factory.call { accept_loop }
        end
        self
      rescue StandardError
        stop
        raise
      end

      # Checks whether the accept worker is alive under the server mutex.
      # @return [Boolean]
      def running?
        @mutex.synchronize { running_locked? }
      end

      # Counts currently live WebSocket connections under the server mutex.
      # @return [Integer]
      def connection_count
        @mutex.synchronize { @connections.count(&:alive?) }
      end

      # Issues a single-use expiring credential for a validated local redirect target.
      # Treat the returned URL as a secret; it establishes the browser session cookie.
      # @param to [String] local target path; invalid targets fall back to /
      # @return [String] authentication URL
      # @raise [Error] if the server is not running
      def launch_url(to: '/')
        raise Error, 'WebUI server is not running' unless running?
        target = valid_redirect_target?(to) ? to : '/'
        token = SecureRandom.hex(32)
        @mutex.synchronize do
          expire_launch_tokens!
          @launch_tokens[token] = monotonic_time + LAUNCH_TOKEN_LIFETIME
        end
        "http://#{url_host}:#{port}/auth?token=#{token}&to=#{URI.encode_www_form_component(target)}"
      end

      # Sends a JSON message to a snapshot of authenticated connections.
      # @param payload [String, Object] already encoded JSON or a JSON-serializable value
      # @return [void]
      def broadcast(payload)
        json = payload.is_a?(String) ? payload : JSON.generate(payload)
        connections = @mutex.synchronize { @connections.dup }
        connections.each { |connection| connection.send_text(json) }
      end

      # Closes admitted HTTP and WebSocket sockets before joining their workers.
      # @return [nil] after listener and client shutdown
      def stop
        server = nil
        accept_thread = nil
        clients = nil
        connections = nil
        sockets = nil
        @mutex.synchronize do
          @stopping = true
          server = @server
          accept_thread = @accept_thread
          clients = @client_threads.dup
          connections = @connections.dup
          sockets = @client_sockets.dup
          @server = nil
          @accept_thread = nil
          @client_threads.clear
          @connections.clear
          @client_sockets.clear
          @launch_tokens.clear
        end
        connections.each(&:close)
        sockets.each do |socket|
          socket.close unless socket.closed?
        rescue IOError, SystemCallError
          nil # The worker may have closed it concurrently.
        end
        server&.close
        join_or_kill(accept_thread)
        clients.each { |thread| join_or_kill(thread) }
        nil
      rescue IOError, SystemCallError
        nil
      end

      # Authenticated WebSocket connection. The viewer id is generated server-side.
      class Connection
        WRITE_TIMEOUT = 10.0

        attr_reader :socket, :viewer_id

        # Wraps an accepted socket with server-generated viewer identity and serialized writes.
        def initialize(socket)
          @socket = socket
          @viewer_id = "viewer-#{SecureRandom.hex(16)}"
          @write_mutex = Mutex.new
          @alive = true
        end

        # Reports whether this transport has been marked open.
        # @return [Boolean]
        def alive? = @alive

        # Writes a text message using the transport's bounded fragmentation encoder.
        # @param payload [String] JSON message text
        # @return [Object] underlying write result
        def send_text(payload)
          write(WebSocket.encode_text_message(payload))
        end

        # Writes a pong control frame through the same serialized connection writer.
        # @param payload [String] ping payload to echo
        # @return [Object] underlying write result
        def send_pong(payload)
          write(WebSocket.encode_frame(payload, opcode: WebSocket::OPCODE_PONG))
        end

        # Sends a best-effort normal Close frame, then shuts down the socket.
        # Never waits for a busy writer or appends a control frame inside a data
        # frame. A blocked/broken connection is instead retired immediately.
        # @return [nil] after shutdown, including repeated calls
        def close
          return unless @alive

          locked = @write_mutex.try_lock
          if locked
            frame = WebSocket.encode_frame([1000].pack('n'), opcode: WebSocket::OPCODE_CLOSE)
            @socket.write_nonblock(frame, exception: false)
          end
          nil
        rescue IOError, SystemCallError
          nil
        ensure
          abort_connection
          @write_mutex.unlock if locked
        end

        private

        # Serializes a complete outbound message within a bounded write deadline.
        # If cancellation unwinds an admitted writer, retire the incomplete stream
        # before releasing its lock so later writers cannot append corrupt frames.
        # @param bytes [String] encoded WebSocket frame bytes
        # @return [Boolean] whether the whole message was written
        # @api private
        def write(bytes)
          return false unless @alive

          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WRITE_TIMEOUT
          locked = false
          until (locked = @write_mutex.try_lock)
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return failed_write if !@alive || remaining <= 0

            sleep([remaining, 0.005].min)
          end
          offset = 0
          while offset < bytes.bytesize
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return failed_write if !@alive || remaining <= 0

            written = @socket.write_nonblock(bytes.byteslice(offset..), exception: false)
            if written == :wait_writable
              return failed_write unless IO.select(nil, [@socket], nil, remaining)
            elsif written.positive?
              offset += written
            else
              return failed_write
            end
          end
          completed = true
        rescue IOError, SystemCallError
          failed_write
        ensure
          if locked
            abort_connection unless completed
            @write_mutex.unlock
          end
        end

        # Retires failed writes without attempting another frame on the stream.
        # @return [false] delivery failed
        # @api private
        def failed_write
          abort_connection
          false
        end

        # Ends transport I/O without acquiring the writer's lock or sending bytes.
        # @return [nil] after socket shutdown or an already-closed socket
        # @api private
        def abort_connection
          @alive = false
          @socket.shutdown(Socket::SHUT_RDWR)
          nil
        rescue IOError, SystemCallError
          nil
        end
      end

      private

      # Reserves a bounded socket slot before starting each request worker.
      # Excess clients are closed immediately without allocating another thread.
      # @return [void]
      def accept_loop
        loop do
          listener = @mutex.synchronize { @server }
          break unless listener

          socket = nil
          socket = listener.accept
          admitted = @mutex.synchronize do
            @client_sockets << socket if !@stopping && @client_sockets.size < MAX_CLIENTS
          end
          unless admitted
            socket.close
            next
          end
          thread = @thread_factory.call(socket) { |client| handle_client_thread(client) }
          @mutex.synchronize do
            @client_threads.reject! { |client| !client.alive? }
            @client_threads << thread if thread.alive?
          end
        rescue IOError, Errno::EBADF
          @mutex.synchronize { @client_sockets.delete(socket) }
          socket&.close unless socket&.closed?
          break if stopping?
          raise
        rescue StandardError => error
          socket&.close
          @mutex.synchronize { @client_sockets.delete(socket) }
          log(:warning, "WebUI accept refusal=#{error.class}")
        end
      end

      # Releases admission even when parsing, dispatch or the worker raises.
      # @param socket [Socket] admitted client, including upgraded WebSockets
      # @return [void]
      def handle_client_thread(socket)
        handle_client(socket)
      ensure
        @mutex.synchronize do
          @client_sockets.delete(socket)
          @client_threads.delete(Thread.current)
        end
      end

      # Dispatches one HTTP request; upgraded sockets remain with their worker.
      # @param socket [Socket] admitted client connection
      # @return [void]
      def handle_client(socket)
        websocket = false
        request = read_request(socket)
        return unless request
        return respond_error(socket, 403, 'Forbidden') unless host_allowed?(request)
        return respond_error(socket, 403, 'Forbidden') unless fetch_metadata_allowed?(request)

        case request[:path]
        when '/auth' then handle_auth(socket, request)
        when '/ws'
          websocket = true
          return handle_websocket(socket, request)
        when *ASSET_ROUTES.keys then handle_asset(socket, request)
        when %r{\A/files/([A-Za-z0-9_-]{1,128})/(.+)\z}
          handle_file(socket, request, Regexp.last_match(1), Regexp.last_match(2))
        else
          respond_error(socket, 404, 'Not Found')
        end
      rescue IOError, SystemCallError
        nil # Disconnect or shutdown can interrupt any read or write.
      rescue StandardError => error
        log(:warning, "WebUI request refused=#{error.class}")
        respond_error(socket, 400, 'Bad Request') unless websocket
      ensure
        begin
          socket.close unless websocket
        rescue IOError, SystemCallError
          nil
        end
      end

      # Reads bounded HTTP headers under a monotonic deadline without accepting a body.
      # @return [Hash, nil] parsed request, or nil on timeout/EOF
      # @raise [Error] for excessive headers
      def read_request(socket)
        deadline = monotonic_time + READ_TIMEOUT
        buffer = +''
        until buffer.include?("\r\n\r\n")
          remaining = deadline - monotonic_time
          return nil unless remaining.positive? && IO.select([socket], nil, nil, remaining)

          chunk = socket.read_nonblock(4096, exception: false)
          return nil if chunk.nil?
          next if chunk == :wait_readable

          buffer << chunk
          raise Error, 'HTTP request headers are too large' if buffer.bytesize > MAX_HEADER_BYTES
        end
        parse_request(buffer)
      end

      # Parses HTTP/1.1 origin-form requests, rejecting duplicate headers and request bodies.
      # @return [Hash] method, path, query, and normalized headers
      # @raise [Error] for malformed or unsupported request framing
      def parse_request(raw)
        head = raw.split("\r\n\r\n", 2).first
        lines = head.split("\r\n")
        method, target, version = lines.shift.to_s.split(' ', 3)
        raise Error, 'malformed request line' unless method && target&.start_with?('/') && version == 'HTTP/1.1'
        raise Error, 'absolute or scheme-relative request target refused' if target.start_with?('//')

        headers = {}
        lines.each do |line|
          name, value = line.split(':', 2)
          raise Error, 'malformed header' unless name && value
          key = name.strip.downcase
          raise Error, "duplicate HTTP header #{key}" if headers.key?(key)
          headers[key] = value.strip
        end
        content_length = Integer(headers.fetch('content-length', '0'), exception: false)
        raise Error, 'invalid Content-Length' unless content_length&.between?(0, Protocol::MAX_MESSAGE_BYTES)
        raise Error, 'request bodies are not accepted' unless content_length.zero?

        path, query = target.split('?', 2)
        { method: method, path: path, query: query, headers: headers }
      end

      # Redeems a short-lived token. File-bootstrap navigation first commits an
      # authenticated document so the next navigation can send a Strict cookie.
      # @param socket [Socket] requesting connection
      # @param request [Hash] parsed HTTP request
      # @return [void]
      def handle_auth(socket, request)
        return respond_error(socket, 405, 'Method Not Allowed') unless request[:method] == 'GET'

        params = URI.decode_www_form(request[:query].to_s).to_h
        token = params['token'].to_s
        accepted = @mutex.synchronize do
          expire_launch_tokens!
          expiry = @launch_tokens.delete(token)
          expiry && expiry >= monotonic_time
        end
        return respond_error(socket, 403, 'Forbidden') unless accepted

        target = valid_redirect_target?(params['to']) ? params['to'] : '/'
        headers = ["Set-Cookie: #{cookie_name}=#{@session_token}; HttpOnly; SameSite=Strict; Path=/"]
        if request[:headers]['sec-fetch-site'] == 'cross-site'
          body = %(<meta http-equiv="refresh" content="0;url=#{CGI.escapeHTML(target)}">)
          respond(socket, 200, 'OK', body, content_type: 'text/html; charset=utf-8', extra_headers: headers)
        else
          respond(socket, 302, 'Found', '', extra_headers: ["Location: #{target}", *headers])
        end
      rescue ArgumentError
        respond_error(socket, 400, 'Bad Request')
      end

      # Serves only allowlisted static assets after authentication and optional-Origin checks.
      # ETags avoid retransmitting unchanged assets; arbitrary filesystem paths are not accepted.
      # @return [void]
      def handle_asset(socket, request)
        return respond_error(socket, 405, 'Method Not Allowed') unless request[:method] == 'GET'
        return respond_error(socket, 403, 'Forbidden') unless authorized?(request)
        return respond_error(socket, 403, 'Forbidden') unless origin_allowed_if_present?(request)

        filename, content_type = ASSET_ROUTES.fetch(request[:path])
        path = File.join(@assets_dir, filename)
        return respond_error(socket, 404, 'Not Found') unless File.file?(path)

        body = File.binread(path)
        etag = %Q("#{Digest::SHA1.hexdigest(body)}")
        if request[:headers]['if-none-match'] == etag
          respond(socket, 304, 'Not Modified', '', extra_headers: ["ETag: #{etag}"])
        else
          respond(socket, 200, 'OK', body, content_type: content_type, extra_headers: ["ETag: #{etag}"])
        end
      end

      # Authenticates an image request before delegating realpath containment to FileService.
      # @return [void]
      def handle_file(socket, request, alias_name, relative_path)
        return respond_error(socket, 405, 'Method Not Allowed') unless request[:method] == 'GET'
        return respond_error(socket, 403, 'Forbidden') unless authorized?(request)
        return respond_error(socket, 403, 'Forbidden') unless origin_allowed_if_present?(request)
        return respond_error(socket, 404, 'Not Found') unless @file_service

        resolved = @file_service.resolve(alias_name, relative_path)
        return respond_error(socket, 404, 'Not Found') unless resolved

        path, content_type, = resolved
        respond(socket, 200, 'OK', File.binread(path), content_type: content_type, cache_control: 'private, max-age=60')
      end

      # Requires cookie authentication and an allowed Origin before creating a connection.
      # Disconnect notification and socket/index cleanup run even when dispatch fails.
      # @return [void]
      def handle_websocket(socket, request)
        unless request[:method] == 'GET' && authorized?(request) && origin_allowed?(request)
          return respond_error(socket, 403, 'Forbidden')
        end
        headers = request[:headers]
        unless headers['upgrade'].to_s.casecmp('websocket').zero? &&
               headers['connection'].to_s.downcase.split(/\s*,\s*/).include?('upgrade') &&
               headers['sec-websocket-version'] == '13' && headers['sec-websocket-key']
          return respond_error(socket, 400, 'Bad Request')
        end

        socket.write(
          "HTTP/1.1 101 Switching Protocols\r\n" \
          "Upgrade: websocket\r\n" \
          "Connection: Upgrade\r\n" \
          "Sec-WebSocket-Accept: #{WebSocket.accept_key(headers['sec-websocket-key'])}\r\n\r\n"
        )
        connection = Connection.new(socket)
        @mutex.synchronize { @connections << connection }
        connection.send_text(Protocol.hello(viewer_id: connection.viewer_id, pages: @pages_provider.call))
        websocket_loop(connection)
      ensure
        if connection
          begin
            @disconnect_handler&.call(connection)
          rescue StandardError => error
            log(:warning, "WebUI disconnect handler failed=#{error.class}")
          end
          connection.close
          @mutex.synchronize { @connections.delete(connection) }
        end
        begin
          socket.close
        rescue IOError, SystemCallError
          nil
        end
      end

      # Processes bounded text/ping frames until close, EOF, or a protocol refusal.
      # @return [void]
      def websocket_loop(connection)
        while connection.alive?
          next unless IO.select([connection.socket], nil, nil, WS_POLL_INTERVAL)

          frame = WebSocket.read_frame(connection.socket)
          break unless frame
          break if frame.close?
          if frame.ping?
            connection.send_pong(frame.payload)
          elsif frame.text?
            dispatch_message(connection, frame.payload)
          end
        end
      rescue WebSocket::ProtocolError => error
        log(:warning, "WebUI websocket refusal=#{error.class}")
      end

      # Validates wire input and returns generic refusals without echoing raw payloads/errors.
      # @return [void]
      def dispatch_message(connection, raw)
        message = Protocol.parse_client_message(raw)
        @message_handler.call(connection, message)
      rescue Protocol::Refusal => error
        log(:warning, "WebUI message refusal=#{error.reason}")
        connection.send_text(Protocol.refusal(reason: error.reason, message: 'Message refused'))
      rescue StandardError => error
        log(:warning, "WebUI handler refusal=#{error.class}")
        connection.send_text(Protocol.refusal(reason: :handler, message: 'Message refused'))
      end

      # Compares the request cookie with this service's session credential.
      # This is service-wide authentication, not owner-specific authorization.
      # @return [Boolean]
      def authorized?(request)
        Protocol.secure_compare(@session_token, cookie_token(request))
      end

      # Extracts this port-named session cookie without treating other cookies as credentials.
      # @return [String, nil] supplied token
      def cookie_token(request)
        request[:headers]['cookie'].to_s.split(';').each do |pair|
          name, value = pair.split('=', 2)
          return value.to_s.strip if name.to_s.strip == cookie_name
        end
        nil
      end

      # Cookies are scoped by host, not by port; simultaneous Lich sessions
      # must not overwrite each other's authentication in the same browser.
      def cookie_name = "#{COOKIE_NAME}_#{port}"

      # Requires an exact allowlisted loopback host and listener port.
      # @return [Boolean]
      def host_allowed?(request)
        allowed_hosts.include?(request[:headers]['host'].to_s)
      end

      def allowed_hosts
        hosts = ["127.0.0.1:#{port}", "localhost:#{port}"]
        hosts << "[::1]:#{port}" if host == '::1'
        hosts
      end

      # Requires an exact HTTP loopback Origin including the service port.
      # @return [Boolean]
      def origin_allowed?(request)
        origin = request[:headers]['origin'].to_s
        allowed_hosts.any? { |allowed| origin == "http://#{allowed}" }
      end

      # Permits omitted Origin for ordinary GETs; supplied origins must match the service.
      # Other authentication, Host, and Fetch Metadata checks still apply.
      # @return [Boolean]
      def origin_allowed_if_present?(request)
        origin = request[:headers]['origin']
        origin.nil? || origin_allowed?(request)
      end

      # Allows cross-site top-level token redemption for file-bootstrap navigation.
      # All authenticated content retains same-origin Fetch Metadata checks.
      # @param request [Hash] parsed HTTP request
      # @return [Boolean] whether browser request metadata permits this route
      def fetch_metadata_allowed?(request)
        site = request[:headers]['sec-fetch-site']
        if request[:path] == '/auth' && site == 'cross-site'
          return request[:headers]['sec-fetch-mode'] == 'navigate' && request[:headers]['sec-fetch-dest'] == 'document'
        end
        return false if site && !%w[same-origin none].include?(site)

        mode = request[:headers]['sec-fetch-mode']
        return true unless mode
        return %w[websocket cors].include?(mode) if request[:path] == '/ws'
        return mode == 'navigate' if request[:path] == '/auth' || request[:path] == '/'

        %w[no-cors same-origin cors].include?(mode)
      end

      def websocket_upgrade?(request)
        request && request[:path] == '/ws' && request[:headers]['upgrade'].to_s.casecmp('websocket').zero?
      end

      # Writes a bounded-handler response with common CSP, no-referrer, and nosniff headers.
      # Responses default to no-store and close the HTTP connection.
      # @return [Object] socket write result
      def respond(socket, status, reason, body, content_type: 'text/plain; charset=utf-8',
                  cache_control: 'no-store', extra_headers: [])
        headers = [
          "HTTP/1.1 #{status} #{reason}", "Content-Length: #{body.bytesize}",
          'Connection: close', "Cache-Control: #{cache_control}", 'Referrer-Policy: no-referrer',
          'X-Content-Type-Options: nosniff', "Content-Security-Policy: #{CSP}",
        ]
        headers << "Content-Type: #{content_type}" unless body.empty?
        headers.concat(extra_headers)
        socket.write(headers.join("\r\n") + "\r\n\r\n" + body)
      end

      def respond_error(socket, status, reason)
        respond(socket, status, reason, reason)
      end

      def expire_launch_tokens!
        now = monotonic_time
        @launch_tokens.delete_if { |_token, expiry| expiry < now }
      end

      # Accepts only local paths without browser-normalized authority delimiters.
      # @param target [Object] decoded redirect destination
      # @return [Boolean] whether the Location stays on this host and port
      def valid_redirect_target?(target)
        target.is_a?(String) && target.start_with?('/') && !target.start_with?('//') && !target.match?(/[\\\x00-\x20\x7f]/)
      end

      def loopback_address?(address)
        LOOPBACK_HOSTS.include?(address)
      end

      def url_host
        host == '::1' ? '[::1]' : host
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def running_locked?
        @accept_thread&.alive? || false
      end

      def stopping?
        @mutex.synchronize { @stopping }
      end

      # Gives a host worker a bounded join before terminating a still-running thread.
      # @return [void]
      def join_or_kill(thread)
        return unless thread

        thread.join(0.5)
        thread.kill if thread.alive?
      end

      def log(level, message)
        @logger.call(level, message)
      rescue StandardError
        nil
      end
    end
  end
end
