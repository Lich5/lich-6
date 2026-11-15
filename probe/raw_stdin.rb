# Prints the raw bytes on stdin as hex, before anything strips them.
$stdin.binmode
puts "RAW #{$stdin.read.unpack1('H*')}"
