# frozen_string_literal: true

# Disposable startup observation only; retire with the testbed after the blocked
# startup call is identified. Records survive the acceptance-root cleanup.
if (artifact = ENV['LICH_CI_DEFAULT_WEBUI_ARTIFACT'])
  diagnostic = File.open("#{artifact}.startup.log", 'a')
  diagnostic.sync = true
  lock = Mutex.new
  record = lambda do |message|
    lock.synchronize do
      diagnostic.puts("#{Process.clock_gettime(Process::CLOCK_MONOTONIC).round(3)} #{message}")
    end
  end
  snapshot = lambda do |stage|
    record.call("#{stage} pid=#{Process.pid}")
    Thread.list.each do |thread|
      record.call("thread=#{thread.object_id} main=#{thread == Thread.main} status=#{thread.status.inspect}\n" \
                  "#{Array(thread.backtrace).join("\n")}")
    end
  end
  record.call("probe_loaded pid=#{Process.pid}")
  observed = %w[lich.rbw gemcheck.rb accepted_gem_policy.rb dependency_recovery.rb bundler_recovery.rb
                runtime_gem_contract.rb init.rb webui_launcher.rb browser_launcher.rb].freeze
  startup_trace = TracePoint.new(:line, :call, :return, :c_call, :c_return, :raise) do |trace|
    next unless observed.include?(File.basename(trace.path.tr('\\', '/')))

    record.call("#{trace.event} #{trace.path}:#{trace.lineno} #{trace.defined_class}##{trace.method_id}")
  end
  startup_trace.enable
  Thread.new do
    [5, 10].each do |delay|
      sleep delay
      snapshot.call('timed_thread_dump')
    end
  end
  at_exit do
    startup_trace.disable
    snapshot.call('process_exit')
  end
end
