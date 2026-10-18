# frozen_string_literal: true

module StreamReplay
  # A captured server stream split into the login header (sent before the probe
  # starts) and the body (replayed one prompt at a time).
  #
  # Format: header lines, a marker line, then body lines. Both the replay marker
  # and benchmark.rb's marker are accepted, so benchmark/fixtures/*.xml replay
  # unchanged. The header must carry <settingsInfo instance='DR|GS...'> and
  # <app char=...> so Lich identifies the game and character (the autostart that
  # launches the probe keys on <app char).
  class Fixture
    MARKERS = ['### stream-replay:body-below ###', '### benchmark:body-repeats-below ###'].freeze

    attr_reader :path, :header_lines, :body_lines, :game

    # Reads and parses a stream fixture.
    # @param path [String] fixture or snapshot file path
    # @return [StreamReplay::Fixture] the parsed fixture read from disk
    def self.load(path)
      new(path, File.read(path))
    end

    # Initializes the fixture and its isolated extraction or replay options.
    # @param path [String] fixture or snapshot file path
    # @param raw [String] captured raw stream text
    # @return [void] initializes isolated fixture extraction or replay state
    def initialize(path, raw)
      @path = path
      marker = MARKERS.find { |m| raw.include?("#{m}\n") }
      raise ArgumentError, "#{path}: no header/body marker (#{MARKERS.join(' or ')})" unless marker

      header, body = raw.split("#{marker}\n", 2)
      @header_lines = header.lines
      @body_lines = body.lines
      @game = header =~ /instance=['"]DR/ ? 'DR' : 'GS'
    end

    # Returns the fixture label used by the replay suite.
    # @return [String] the fixture basename without its XML extension
    def name
      File.basename(path, '.xml')
    end
  end
end
