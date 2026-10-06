# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        module StyleProvider
          PRIORITY_USER = 800
        end

        class Settings
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

          def load(data:)
            valid = data.is_a?(String) && data.length <= 8192
            valid &&= data.match?(/\Alabel\s*\{\s*font-weight:\s*bold;\s*\}\s*trough\s*\{\s*font-weight:\s*bold;\s*min-height:\s*22px;\s*\}\s*progress\s*\{\s*font-weight:\s*bold;\s*min-height:\s*20px;\s*background-image:\s*none;\s*background-color:\s*(?:#[0-9a-fA-F]{6}|[a-z]+);\s*\}\z/)
            Gtk.session.refuse(self, :load) unless valid
            color = data.match(/background-color:\s*([^;]+);/)[1]
            @fill_color = Color.parse(color) || Gtk.session.refuse(self, :load)
            @loaded = true
          end

          def loaded? = @loaded == true
        end

        class StyleContext
          def initialize(widget)
            @widget = widget
          end

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

          def self.parse(value)
            hex = value.match?(/\A#[0-9a-fA-F]{6}\z/) ? value.delete_prefix('#') : NAMES[value]
            return unless hex

            r, g, b = hex.scan(/../).map { |channel| channel.to_i(16) }
            { r: r, g: g, b: b, a: 1.0 }.freeze
          end
        end
        private_constant :Color
      end

      module Gdk
        # Colour values are validated locally and never interpreted as CSS.
        class RGBA
          def initialize(*channels)
            Gtk.session.refuse(self, :new) unless channels.length == 4 && channels.all? { |channel| channel.is_a?(Numeric) && channel.finite? && channel.between?(0, 1) }
          end

          def self.parse(value)
            channels = { 'green' => [0, 1, 0, 1], 'red' => [1, 0, 0, 1] }[value]
            Gtk.session.refuse(self, :parse) unless channels
            new(*channels)
          end
        end

        # Screen dimensions are a declared degradation: this nominal work area
        # supplies initial size hints only; the browser host controls placement.
        class Screen
          def self.default
            Gtk.session.degrade(:screen_geometry, 'nominal initial size; browser host owns screen geometry')
            new
          end

          def width = 1024
          def height = 768
        end

        def self.const_missing(name)
          Gtk.session.refuse(self, name)
        end
      end

      # These value objects translate measured style requests to contract tokens.
      # They do not load Pango or expose arbitrary browser CSS.
      module Pango
        class FontDescription
          attr_reader :weight

          def initialize
            @weight = :normal
          end

          def self.from_string(value)
            Gtk.session.refuse(self, :from_string) unless value.is_a?(String) && value.length.between?(1, 512)
            new
          end

          def weight=(value)
            Gtk.session.refuse(self, :weight=) unless %i[normal bold].include?(value)
            @weight = value
          end

          def method_missing(name, *, **, &)
            Gtk.session.refuse(self, name)
          end

          def respond_to_missing?(*args)
            super
          end
        end

        def self.const_missing(name)
          Gtk.session.refuse(self, name)
        end
      end
    end
  end
end
