# lib/remote_syslog_sender/log.rb
require "logger"
require "json"

module RemoteSyslogSender
    module Log
        def self.logger
            @logger ||= Logger.new('/root/remote_syslog_sender.log', 14, 10240000).tap do |log|
                log.level = Logger::DEBUG
            end
        end

        def self.logger=(custom_logger)
            @logger = custom_logger
        end
    end
end

def decode_message_in_log_line(line)
    # Najdi message:JSON a převeď jej na čitelný
    if line =~ /message:({.*?})(?=\s\w+:|$)/
        raw_json = $1
        begin
            decoded_json = JSON.pretty_generate(JSON.parse(raw_json)).gsub("\n", '').gsub(/\s+/, ' ')
            return line.sub(raw_json, decoded_json)
        rescue JSON::ParserError => e
            return line
        end
    else
        line
    end
end
