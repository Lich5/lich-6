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

          def gtk_application_prefer_dark_theme?
            Gtk.session.degrade(:theme_preference, 'nominal dark palette hint; the browser controls the actual theme')
            true
          end
        end

        # spellson's measured CSS is presentation-only. Validate its narrow
        # vocabulary, report the loss, and never execute source CSS in a page.
        class CssProvider
          def load(data:)
            valid = data.is_a?(String) && data.length <= 8192
            valid &&= data.match?(/\Alabel\s*\{\s*font-weight:\s*bold;\s*\}\s*trough\s*\{\s*font-weight:\s*bold;\s*min-height:\s*22px;\s*\}\s*progress\s*\{\s*font-weight:\s*bold;\s*min-height:\s*20px;\s*background-image:\s*none;\s*background-color:\s*(?:#[0-9a-fA-F]{6}|[a-z]+);\s*\}\z/)
            Gtk.session.refuse(self, :load) unless valid
            @loaded = true
          end

          def loaded? = @loaded == true
        end

        class StyleContext
          def add_provider(provider, priority)
            Gtk.session.refuse(self, :add_provider) unless provider.is_a?(CssProvider) && provider.loaded? && priority == StyleProvider::PRIORITY_USER
            Gtk.session.degrade(:progress_css, 'spell bar colours and font weights follow browser theme; names and durations remain visible')
          end
        end
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
