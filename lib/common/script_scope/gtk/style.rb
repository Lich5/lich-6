# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        module StyleProvider
          PRIORITY_APPLICATION = 600
          PRIORITY_USER = 800
        end

        class Settings
          # Returns a lightweight preference facade; no native GTK settings object exists.
          # @return [Settings]
          def self.default = new

          # Reports the same preference as native pages so scripts can choose
          # their original light/dark palettes without GTK runtime dependencies.
          # @return [Boolean] whether the application prefers the dark theme
          def gtk_application_prefer_dark_theme?
            Lich::WebUI::Theme.current == :dark
          end
        end

        # Preserve measured progress declarations and explicitly omit other CSS.
        # The browser receives bounded color/geometry values, never source CSS.
        class CssProvider
          attr_reader :session, :fill_color, :state

          # Captures the creating owner; retained providers cannot cross sessions.
          def initialize
            @session = Gtk.session
            @contexts = {}.compare_by_identity
            @state = :unloaded
          end

          # Recognizes measured progress styling or omits decoration with a notice.
          # Omitted CSS is inert and is not retained, parsed further or sent to the renderer.
          # @param data [String] stylesheet, at most 8,192 characters
          # @return [Boolean] true on recognized or omitted decoration
          # @raise [UnsupportedOperation] for invalid input or owner/lifetime violations
          def load(data:)
            session.style_operation(self, :load) do
              valid = data.is_a?(String) && data.valid_encoding? && data.encoding.ascii_compatible? && data.length <= 8192
              session.refuse(self, :load) unless valid
              match = data.match(/\Alabel\s*\{\s*font-weight:\s*bold;\s*\}\s*trough\s*\{\s*font-weight:\s*bold;\s*min-height:\s*22px;\s*\}\s*progress\s*\{\s*font-weight:\s*bold;\s*min-height:\s*20px;\s*background-image:\s*none;\s*background-color:\s*(#[0-9a-fA-F]{6}|[a-z]+)\s*;?\s*\}\z/)
              color = Color.parse(match[1]) if match
              @fill_color = color
              @state = color ? :recognized : :omitted
              session.degrade(:css_decoration, 'CSS decoration omitted; supported controls use the WebUI theme', receiver: self) unless color
              @contexts.each_key { |context| context.send(:refresh) }
              true
            end
          end

          # Positional GTK spelling; shares validation and reload notification.
          # @param data [String] bounded stylesheet
          # @return [Boolean] true on successful load
          def load_from_data(data)
            load(data: data)
          end

          # Reports a completed load, including explicitly omitted decoration.
          # @return [Boolean]
          def loaded? = @state != :unloaded

          # Refuses style APIs outside the measured progress surface.
          # @raise [UnsupportedOperation] always
          def method_missing(name, *, **, &)
            session.refuse(self, name)
          end

          # Keeps unsupported methods absent from reflection.
          def respond_to_missing?(*args) = super

          private

          def attach(context)
            @contexts[context] = true
          end

          def detach(context)
            @contexts.delete(context)
          end
        end

        class StyleContext
          # Binds the restricted style facade to its compatibility widget.
          def initialize(widget)
            @session = Gtk.session
            @session.refuse(self, :new) unless widget.is_a?(ProgressBar) && widget.session.equal?(@session) && !widget.destroyed?
            @widget = widget
            @providers = {}.compare_by_identity
            @session.register_style_context(self)
          end

          # Attaches before or after load. Higher priority wins; the most recent
          # attachment breaks ties. Reattaching replaces the existing registration.
          # @param provider [CssProvider] provider from this owner
          # @param priority [Integer] APPLICATION (default) or USER
          # @return [StyleContext] self
          def add_provider(provider, priority = StyleProvider::PRIORITY_APPLICATION)
            operation(:add_provider) do
              validate_provider(provider, :add_provider)
              valid = priority.is_a?(Integer) && [StyleProvider::PRIORITY_APPLICATION, StyleProvider::PRIORITY_USER].include?(priority)
              @session.refuse(self, :add_provider) unless valid && (@providers.key?(provider) || @providers.size < 64)
              @providers.delete(provider)
              @providers[provider] = priority
              provider.send(:attach, self)
              refresh
            end
            self
          end

          # Removes only this context's registration; missing same-owner providers
          # are harmless. Remaining providers or authored/default values reappear.
          # @return [StyleContext] self
          def remove_provider(provider)
            operation(:remove_provider) do
              validate_provider(provider, :remove_provider)
              @providers.delete(provider)
              provider.send(:detach, self)
              refresh
            end
            self
          end

          # Unknown style behavior remains an attributed hard stop.
          # @raise [UnsupportedOperation] always
          def method_missing(name, *, **, &)
            @session.refuse(self, name)
          end

          # Keeps unsupported methods absent from reflection.
          def respond_to_missing?(*args) = super

          private

          def operation(name, &block)
            @session.style_operation(self, name) do
              @session.refuse(self, name) unless @widget && !@widget.destroyed?
              block.call
            end
          end

          def validate_provider(provider, operation)
            @session.refuse(self, operation) unless provider.is_a?(CssProvider) && provider.session.equal?(@session)
          end

          def refresh
            candidates = @providers.each_with_index.select { |(provider, _priority), _index| provider.state == :recognized }
            selected = candidates.max_by { |(_provider, priority), index| [priority, index] }
            provider = selected&.first&.first
            # GTK's 22px trough content includes a one-pixel border on each side.
            @widget.send(:apply_progress_style, provider ? { fill_color: provider.fill_color, height: 24 } : {})
          end

          def close
            @session.synchronize do
              @providers.each_key { |provider| provider.send(:detach, self) }
              @providers.clear
              @widget = nil
              @session.forget_style_context(self)
            end
          end
        end

        # Named colors are limited to the observed spell palettes and boon tip.
        # No browser CSS parsing, URLs, functions, or arbitrary style strings.
        module Color
          NAMES = {
            'violet' => 'ee82ee', 'orchid' => 'da70d6', 'powderblue' => 'b0e0e6',
            'skyblue' => '87ceeb', 'greenyellow' => 'adff2f', 'hotpink' => 'ff69b4',
            'deepskyblue' => '00bfff', 'gold' => 'ffd700', 'burlywood' => 'deb887',
            'lightcoral' => 'f08080', 'lightgray' => 'd3d3d3', 'lime' => '00ff00',
            'lightgreen' => '90ee90', 'lightsteelblue' => 'b0c4de',
            'turquoise' => '40e0d0', 'lightsalmon' => 'ffa07a', 'blue' => '0000ff',
          }.freeze

          # Maps an allowed name or six-/twelve-digit RGB literal to numeric contract channels.
          # @return [Hash, nil] frozen RGBA record, or nil for an unsupported color
          def self.parse(value)
            hex = value.match?(/\A#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{12})\z/) ? value.delete_prefix('#') : NAMES[value]
            return unless hex

            width = hex.length / 3
            r, g, b = hex.scan(/.{#{width}}/).map { |channel| (channel.to_i(16) * 255.0 / (16**width - 1)).round }
            { r: r, g: g, b: b, a: 1.0 }.freeze
          end
        end
        private_constant :Color
      end

      module Gdk
        # Colour values are validated locally and never interpreted as CSS.
        class RGBA
          # Validates four finite unit-interval channels for the accepted background-color call.
          # The object is a compatibility token; it does not retain arbitrary native color state.
          # @raise [UnsupportedOperation] for invalid channels
          def initialize(*channels)
            Gtk.session.refuse(self, :new) unless channels.length == 4 && channels.all? { |channel| channel.is_a?(Numeric) && channel.finite? && channel.between?(0, 1) }
          end

          # Accepts the measured red/green compatibility names only.
          # @return [RGBA]
          # @raise [UnsupportedOperation] for other values
          def self.parse(value)
            channels = { 'green' => [0, 1, 0, 1], 'red' => [1, 0, 0, 1] }[value]
            Gtk.session.refuse(self, :parse) unless channels
            new(*channels)
          end
        end

        # Screen dimensions are a declared degradation: this nominal work area
        # supplies initial size hints only; the browser host controls placement.
        class Screen
          # Reports nominal screen geometry as a degradation instead of querying an OS display.
          # @return [Screen] initial-size hint provider
          def self.default
            Gtk.session.degrade(:screen_geometry, 'nominal initial size; browser host owns screen geometry')
            new
          end

          # Supplies a nominal initial width, not a measurement of the user's display.
          # @return [Integer] 1024
          def width = 1024
          # Supplies a nominal initial height, not a measurement of the user's display.
          # @return [Integer] 768
          def height = 768
        end

        # Refuses GDK facilities outside the bounded compatibility constants.
        # @raise [Gtk::UnsupportedOperation] always
        def self.const_missing(name)
          Gtk.session.refuse(self, name)
        end
      end

      # These value objects translate measured style requests to contract tokens.
      # They do not load Pango or expose arbitrary browser CSS.
      module Pango
        class FontDescription
          attr_reader :weight

          # Creates the supported font-weight token, initially normal.
          def initialize
            @weight = :normal
          end

          # Accepts a bounded nonempty description without parsing font family or size.
          # @return [FontDescription] normal-weight token
          # @raise [Gtk::UnsupportedOperation] for an invalid description
          def self.from_string(value)
            Gtk.session.refuse(self, :from_string) unless value.is_a?(String) && value.length.between?(1, 512)
            new
          end

          def weight=(value)
            Gtk.session.refuse(self, :weight=) unless %i[normal bold].include?(value)
            @weight = value
          end

          # Refuses font operations outside the supported weight token.
          # @raise [Gtk::UnsupportedOperation] always
          def method_missing(name, *, **, &)
            Gtk.session.refuse(self, name)
          end

          # Does not advertise native font methods beyond this compatibility object's implementation.
          # @return [Boolean]
          def respond_to_missing?(*args)
            super
          end
        end

        # Refuses unsupported Pango types without loading its native library.
        # @raise [Gtk::UnsupportedOperation] always
        def self.const_missing(name)
          Gtk.session.refuse(self, name)
        end
      end
    end
  end
end
