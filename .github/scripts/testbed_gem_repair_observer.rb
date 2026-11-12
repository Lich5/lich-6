# frozen_string_literal: true

# Observe actual startup and repair; never replace a GemCheck decision or method.
# Retire with this disposable no-DevKit experiment after its result is recorded.
directory = ENV.fetch('LICH_TESTBED_REPAIR_ARTIFACTS')
File.write(File.join(directory, "process-#{Process.pid}.txt"), $PROGRAM_NAME)
write_record = lambda do |name, data|
  path = File.join(directory, name)
  File.write("#{path}.tmp", JSON.pretty_generate(data))
  File.rename("#{path}.tmp", path)
end
observer = TracePoint.new(:return) do |event|
  path = event.path.tr('\\', '/')
  if path.end_with?('/dependency_recovery.rb') && event.method_id == :fetch && event.return_value.is_a?(String)
    File.write(File.join(directory, "manifest-#{Process.pid}.json"), event.return_value)
  elsif path.end_with?('/accepted_gem_policy.rb') && event.method_id == :check
    check = event.return_value
    next unless check.respond_to?(:needed)

    write_record.call("policy-#{Process.pid}.json", {
      pid: Process.pid, needed: check.needed, units: check.plan.units.map { |unit| unit.fetch('id') },
      gem_home: Gem.dir, gem_path: Gem.path,
      installed: Gem::Specification.map { |spec| [spec.name, spec.version.to_s, spec.platform.to_s] },
      active: Gem.loaded_specs.values.map { |spec| [spec.name, spec.version.to_s, spec.platform.to_s] }
    })
  elsif path.end_with?('/accepted_gem_policy.rb') && event.method_id == :activate! && event.return_value == true
    write_record.call('ready.json', { pid: Process.pid, accepted_runtime_activated: true })
    observer.disable
  end
end
observer.enable
