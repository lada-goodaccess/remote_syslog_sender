require 'socket'
require 'syslog_protocol'
require 'remote_syslog_sender/sender'
require 'remote_syslog_sender/log'
require 'timeout'

module RemoteSyslogSender
  class TcpSender < Sender
    class NonBlockingTimeout < StandardError; end

    def initialize(remote_hostname, remote_port, options = {})
      super
      @tls             = options[:tls]
      @retry_limit     = options[:retry_limit] || 3
      @retry_interval  = options[:retry_interval] || 0.5
      @remote_hostname = remote_hostname
      @remote_port     = remote_port
      @ssl_method      = options[:ssl_method] || 'TLSv1_2'
      @ca_file         = options[:ca_file]
      @verify_mode     = options[:verify_mode]
      @timeout         = options[:timeout] || 600
      @timeout_exception   = !!options[:timeout_exception]
      @exponential_backoff = !!options[:exponential_backoff]
      @tcp_user_timeout = options[:tcp_user_timeout] || 5000

      @mutex = Mutex.new
      @tcp_socket = nil

      if [:SOL_SOCKET, :SO_KEEPALIVE, :IPPROTO_TCP, :TCP_KEEPIDLE].all? {|c| Socket.const_defined? c}
        @keep_alive      = options[:keep_alive]
      end
      if Socket.const_defined?(:TCP_KEEPIDLE)
        @keep_alive_idle = options[:keep_alive_idle]
      end
      if Socket.const_defined?(:TCP_KEEPCNT)
        @keep_alive_cnt  = options[:keep_alive_cnt]
      end
      if Socket.const_defined?(:TCP_KEEPINTVL)
        @keep_alive_intvl = options[:keep_alive_intvl]
      end
      connect
    end

    def close
      @socket.close if @socket
      @tcp_socket.close if @tcp_socket
    end

    private

    def connect
      connect_retry_count = 0
      connect_retry_limit = 0
      connect_retry_interval = 0
      connect_timeout = 5

      @mutex.synchronize do
        begin
          close

          if @timeout && @timeout >= 0
            begin
              Timeout.timeout(connect_timeout) do
                @tcp_socket = TCPSocket.new(@remote_hostname, @remote_port)
              end
            rescue Timeout::Error => e
              raise Timeout::Error, "[TCP] Timeout while connecting to #{@remote_hostname}:#{@remote_port}"
            end
          else
            @tcp_socket = TCPSocket.new(@remote_hostname, @remote_port)
          end

          @tcp_socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_USER_TIMEOUT, @tcp_user_timeout) if @tcp_user_timeout

          if @keep_alive
            @tcp_socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
            @tcp_socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPIDLE, @keep_alive_idle) if @keep_alive_idle
            @tcp_socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPCNT, @keep_alive_cnt) if @keep_alive_cnt
            @tcp_socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPINTVL, @keep_alive_intvl) if @keep_alive_intvl
          end
          if @tls
            require 'openssl'
            context = OpenSSL::SSL::SSLContext.new(@ssl_method)
            context.ca_file = @ca_file if @ca_file
            context.verify_mode = @verify_mode if @verify_mode

            @socket = OpenSSL::SSL::SSLSocket.new(@tcp_socket, context)
            # GoodAccess - Add SNI to SSL context
            @socket.hostname = @remote_hostname

            if @timeout && @timeout >= 0
              begin
                Timeout.timeout(connect_timeout) do
                  @socket.connect
                end
              rescue Timeout::Error => e
                raise Timeout::Error, "[TLS] Timeout while connecting to #{@remote_hostname}:#{@remote_port}"
              end
            else
              @socket.connect
            end
            if @verify_mode != OpenSSL::SSL::VERIFY_NONE
              @socket.post_connection_check(@remote_hostname)
              raise "verification error" if @socket.verify_result != OpenSSL::X509::V_OK
            end
          else
            @socket = @tcp_socket
          end
        rescue
          if connect_retry_count < connect_retry_limit
            sleep connect_retry_interval
            connect_retry_count += 1
            retry
          else
            raise
          end
        end
      end
    end

    def send_msg(payload)
      if @timeout && @timeout >= 0
        method = :write_nonblock
      else
        method = :write
      end

      retry_limit = @retry_limit.to_i
      retry_interval = @retry_interval.to_f
      retry_count = 0

      payload << "\n"
      payload.force_encoding(Encoding::ASCII_8BIT)
      payload_size = payload.bytesize

      RemoteSyslogSender::Log.logger.debug("#{@tls ? '[TLS]' : '[TCP]'} Sending payload [#{payload_size}b] to #{@remote_hostname}:#{@remote_port}: #{decode_message_in_log_line(payload).rstrip}")

      begin
        if !@tls && @socket.is_a?(TCPSocket)
          ready = IO.select([@socket], nil, nil, 0) # timeout 0 = non-blocking
          if ready
            begin
              data = @socket.recv(1, Socket::MSG_PEEK)
              if data.empty?
                raise IOError, "#{@tls ? '[TLS]' : '[TCP]'} Remote closed connection (FIN received)"
              end
            rescue Errno::ECONNRESET, Errno::ENOTCONN => e
              raise IOError, "#{@tls ? '[TLS]' : '[TCP]'} Socket not connected or reset: #{e}"
            end
          end
        end

        until payload_size <= 0
          start = get_time
          begin
            result = @mutex.synchronize do
              if @tls && @timeout && @timeout >= 0
                begin
                  Timeout.timeout(@timeout) do
                    @socket.__send__(method, payload)
                  end
                rescue Timeout::Error => e
                  raise Timeout::Error, "#{@tls ? '[TLS]' : '[TCP]'} Timeout while sending to #{@remote_hostname}:#{@remote_port}"
                end
              else
                @socket.__send__(method, payload)
              end
            end
            payload_size -= result
            payload.slice!(0, result) if payload_size > 0

          rescue IO::WaitReadable
            timeout_wait = @timeout - (get_time - start)
            retry if IO.select([@socket], nil, nil, timeout_wait)
            raise NonBlockingTimeout if @timeout_exception
            break

          rescue IO::WaitWritable
            timeout_wait = @timeout - (get_time - start)
            retry if IO.select(nil, [@socket], nil, timeout_wait)
            raise NonBlockingTimeout if @timeout_exception
            break
          end
        end

      rescue => e
        if retry_count < retry_limit
          RemoteSyslogSender::Log.logger.error("#{@tls ? '[TLS]' : '[TCP]'} Error sending message to #{@remote_hostname}:#{@remote_port}, error: #{e.class}: #{e.message} — reconnecting and retrying...")
          sleep retry_interval
          retry_count += 1
          retry_interval *= 2 if @exponential_backoff
          connect
          retry
        else
          RemoteSyslogSender::Log.logger.error("#{@tls ? '[TLS]' : '[TCP]'} Failed to send message to #{@remote_hostname}:#{@remote_port} after #{retry_count} retries. Giving up. Error: #{e.class}: #{e.message}")
          raise
        end
      end
      RemoteSyslogSender::Log.logger.debug("#{@tls ? '[TLS]' : '[TCP]'} Successfully sent payload to #{@remote_hostname}:#{@remote_port}")
    end

    POSIX_CLOCK =
      if defined?(Process::CLOCK_MONOTONIC_COARSE)
        Process::CLOCK_MONOTONIC_COARSE
      elsif defined?(Process::CLOCK_MONOTONIC)
        Process::CLOCK_MONOTONIC
      elsif defined?(Process::CLOCK_REALTIME_COARSE)
        Process::CLOCK_REALTIME_COARSE
      elsif defined?(Process::CLOCK_REALTIME)
        Process::CLOCK_REALTIME
      end

    def get_time
      if POSIX_CLOCK
        Process.clock_gettime(POSIX_CLOCK)
      else
        Time.now.to_f
      end
    end
  end
end
