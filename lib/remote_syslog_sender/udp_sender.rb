require 'socket'
require 'syslog_protocol'
require 'remote_syslog_sender/sender'
require 'remote_syslog_sender/log'

module RemoteSyslogSender
  class UdpSender < Sender
    def initialize(remote_hostname, remote_port, options = {})
      super
      @socket = UDPSocket.new
    end

    private

    def send_msg(payload)
      payload << "\n"
      payload.force_encoding(Encoding::ASCII_8BIT)
      payload_size = payload.bytesize

      RemoteSyslogSender::Log.logger.debug("[UDP] Sending payload [#{payload_size}b] to #{@remote_hostname}:#{@remote_port}: #{decode_message_in_log_line(payload).rstrip}")
      @socket.send(payload, 0, @remote_hostname, @remote_port)
    end
  end
end
