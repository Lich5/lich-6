# frozen_string_literal: true

require 'socket'

socket = TCPSocket.new(ARGV.fetch(0), Integer(ARGV.fetch(1)))
sleep 30
socket.close
