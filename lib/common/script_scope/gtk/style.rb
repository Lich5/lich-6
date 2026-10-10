# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        module StyleProvider
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

        # Parse only the stylesheet actually used by the accepted spell monitor.
        # The browser receives bounded color/geometry values, never source CSS.
        class CssProvider
          attr_reader :fill_color

          # Accepts the measured progress stylesheet grammar and extracts a bounded fill color.
          # Arbitrary CSS never reaches the renderer.
          # @param data [String] supported stylesheet, at most 8,192 characters
          # @raise [UnsupportedOperation] for any unsupported grammar or color
          def load(data:)
            valid = data.is_a?(String) && data.length <= 8192
            valid &&= data.match?(/\Alabel\s*\{\s*font-weight:\s*bold;\s*\}\s*trough\s*\{\s*font-weight:\s*bold;\s*min-height:\s*22px;\s*\}\s*progress\s*\{\s*font-weight:\s*bold;\s*min-height:\s*20px;\s*background-image:\s*none;\s*background-color:\s*(?:#[0-9a-fA-F]{6}|[a-z]+);\s*\}\z/)
            Gtk.session.refuse(self, :load) unless valid
            color = data.match(/background-color:\s*([^;]+);/)[1]
            @fill_color = Color.parse(color) || Gtk.session.refuse(self, :load)
            @loaded = true
          end

          # Reports successful validation of this provider's stylesheet.
          # @return [Boolean]
          def loaded? = @loaded == true
        end

        class StyleContext
          # Binds the restricted style facade to its compatibility widget.
          def initialize(widget)
            @widget = widget
          end

          # Maps the accepted user-priority provider to progress fill and trough height.
          # @raise [UnsupportedOperation] for other providers, unloaded CSS, or priorities
          def add_provider(provider, priority)
            Gtk.session.refuse(self, :add_provider) unless provider.is_a?(CssProvider) && provider.loaded? && priority == StyleProvider::PRIORITY_USER
            @widget.send(:write, :fill_color, provider.fill_color)
            # GTK's 22px trough content has a one-pixel border on both sides.
            @widget.send(:write, :height, 24)
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
