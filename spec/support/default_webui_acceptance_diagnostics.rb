# frozen_string_literal: true

# Disposable Windows startup diagnostics: retire once a native Windows receipt
# identifies the stalled stage and the underlying startup failure is resolved.
module DefaultWebUIAcceptanceDiagnostics
  module_function

  # Appends one fixed probe stage without recording URLs or authentication data.
  # @param root [String] supervisor-owned temporary root
  # @param stage [String] fixed stage literal from the probe
  # @return [void]
  # @api private
  def mark(root, stage)
    File.open(File.join(root, 'progress.log'), 'a') { |file| file.puts(stage) }
    nil
  end

  # Retains progress and isolated startup logs before the supervisor removes them.
  # Invalid log bytes become replacement characters so JSON remains publishable.
  # @param root [String] supervisor-owned temporary root after child exit
  # @return [Hash] observed stages and startup log contents, with nil if no stage ran
  # @api private
  def capture(root)
    progress = File.join(root, 'progress.log')
    stages = File.file?(progress) ? File.readlines(progress, chomp: true) : []
    logs = Dir.glob(File.join(root, 'temp', '*.log')).sort.each_with_object({}) do |path, retained|
      next if File.symlink?(path) || !File.file?(path)

      retained["temp/#{File.basename(path)}"] = File.binread(path).force_encoding(Encoding::UTF_8).scrub
    end
    { 'last_startup_stage' => stages.last, 'startup_stages' => stages, 'startup_logs' => logs }
  end
end
