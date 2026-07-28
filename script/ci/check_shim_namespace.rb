#!/usr/bin/env ruby
# frozen_string_literal: true

require 'find'
require 'ripper'

root = File.expand_path(ARGV.fetch(0, Dir.pwd))
shim = File.join(root, 'lib/common/script_scope/gtk')
violations = []

constant_path = lambda do |node|
  next [] unless node.is_a?(Array)

  case node[0]
  when :@const
    [node[1]]
  when :var_ref, :const_ref, :top_const_ref
    constant_path.call(node[1])
  when :const_path_ref, :const_path_field
    constant_path.call(node[1]) + constant_path.call(node[2])
  else
    []
  end
end

shim_path = lambda do |path|
  path.each_cons(2).any? { |left, right| left == 'ScriptScope' && right == 'Gtk' }
end

references_shim = lambda do |node, namespace = []|
  next false unless node.is_a?(Array)

  if %i[module class].include?(node[0])
    declared_path = constant_path.call(node[1])
    next true if shim_path.call(declared_path)

    nested_namespace = declared_path.length > 1 ? declared_path : namespace + declared_path
    body = node[node[0] == :module ? 2 : 3]
    next references_shim.call(body, nested_namespace)
  end

  path = constant_path.call(node)
  next true if shim_path.call(path)

  inside_script_scope = namespace.each_cons(3).any? { |names| names == %w[Lich Common ScriptScope] }
  next true if node[0] == :@const && node[1] == 'Gtk' && inside_script_scope

  node.any? { |child| child.is_a?(Array) && references_shim.call(child, namespace) }
end

Find.find(root) do |path|
  next if path.start_with?("#{shim}#{File::SEPARATOR}") || path.include?('/.git/')
  next unless File.file?(path) && (path.end_with?('.rb', '.lic', '.rbw'))

  syntax_tree = Ripper.sexp(File.read(path))
  violations << path if syntax_tree && references_shim.call(syntax_tree)
end

abort "shim namespace reference outside #{shim}: #{violations.join(', ')}" unless violations.empty?
