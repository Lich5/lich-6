#!/usr/bin/env ruby
# frozen_string_literal: true

require 'find'
require 'ripper'

root = File.expand_path(ARGV.fetch(0, Dir.pwd))
shim = File.join(root, 'lib/common/script_scope/gtk')
targets = [File.join(root, 'lich.rbw'), File.join(root, 'lib')]
gtk_constants = %w[Gtk GLib Gdk GdkPixbuf Pango HAVE_GTK GtkCompaction].freeze
violations = []

targets.each do |target|
  next unless File.exist?(target)

  paths = File.file?(target) ? [target] : Find.find(target)
  paths.each do |path|
    next if path.start_with?("#{shim}#{File::SEPARATOR}")
    next unless File.file?(path) && (path.end_with?('.rb') || path.end_with?('.rbw'))

    source = File.read(path)
    Ripper.lex(source).each do |position, event, token|
      next unless (event == :on_const && gtk_constants.include?(token)) ||
                  (event == :on_ident && token.match?(/gtk/i))

      violations << "#{path}:#{position.fetch(0)}:#{token}"
    end
    source.each_line.with_index(1) do |line, line_number|
      next if line.lstrip.start_with?('#')
      next unless line.match?(/\brequire(?:_relative)?\b.*['"][^'"]*gtk/i)

      violations << "#{path}:#{line_number}:GTK require"
    end
  end
end

abort "GTK runtime idiom outside #{shim}: #{violations.uniq.join(', ')}" unless violations.empty?
