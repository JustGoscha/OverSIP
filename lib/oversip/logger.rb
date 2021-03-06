module OverSIP

  # Logging client module. Any class desiring to log messages must include (or extend) this module.
  # In order to identify itself in the logs, the class can define log_ig() method or set @log_id
  # attribute.
  module Logger

    def self.init_logger_mq group=nil
      @@logger_mq = ::OverSIP::PosixMQ.create_queue({
        :name    => ::OverSIP.syslogger_mq_name,
        :mode    => :write,
        :maxmsg  => 1000,
        :msgsize => 2000,
        :group => group
      })
    end


    def self.load_methods
      # When not yet daemonized, also log to syslog.
      if not ::OverSIP.daemonized?
        ::Syslog.close  if ::Syslog.opened?

        syslog_options = ::Syslog::LOG_PID | ::Syslog::LOG_NDELAY
        syslog_facility = ::OverSIP::Syslog::SYSLOG_FACILITY_MAPPING[::OverSIP.configuration[:core][:syslog_facility]] rescue ::Syslog::LOG_DAEMON
        ::Syslog.open(::OverSIP.master_name, syslog_options, syslog_facility)
      end

      begin
        @@threshold = ::OverSIP::Syslog::SYSLOG_SEVERITY_MAPPING[::OverSIP.configuration[:core][:syslog_level]]
      rescue
        @@threshold = 0  # debug.
      end

      $oversip_debug = ( @@threshold == 0 ? true : false )

      @@congested = false

      ::OverSIP::Syslog::SYSLOG_SEVERITY_MAPPING.each do |level, level_value|
        method_str = "
          def log_system_#{level}(msg)
        "

        if ::OverSIP.syslogger_ready?
          method_str << "
            return false if @@threshold > #{level_value} || @@congested
            begin
              unless @@logger_mq.trysend ::OverSIP::Logger.syslog_system_msg2str(#{level_value}, msg, log_id), 0
                @@congested = true
                ::EM.add_timer(1) do
                  @@logger_mq.trysend ::OverSIP::Logger.syslog_system_msg2str(4, \"logger message queue was full, some logs have been lost\", log_id), 1
                  @@congested = false
                end
              end
            rescue ::Errno::EMSGSIZE
              @@logger_mq.trysend ::OverSIP::Logger.syslog_system_msg2str(4, \"too long message could not be logged\", log_id), 1 rescue nil
            rescue ::Exception => e
              @@logger_mq.trysend ::OverSIP::Logger.syslog_system_msg2str(4, \"unexpected logging error (\#{e.class}: \#{e.message})\", log_id), 1 rescue nil
            end
          "
        end

        if not ::OverSIP.daemonized?
          if %w{debug info notice}.include? level
            method_str << "
              puts ::OverSIP::Logger.fg_system_msg2str('#{level}', msg, log_id)
              if not ::OverSIP.syslogger_ready?
                ::OverSIP::Syslog.log ::OverSIP::Logger.syslog_system_msg2str(#{level_value}, msg, log_id)
              end
            "
          else
            method_str << "
              $stderr.puts ::OverSIP::Logger.fg_system_msg2str('#{level}', msg, log_id)
              if not ::OverSIP.syslogger_ready?
                ::OverSIP::Syslog.log ::OverSIP::Logger.syslog_system_msg2str(#{level_value}, msg, log_id)
              end
            "
          end
        end

        method_str << "end"

        self.module_eval method_str


        if ::OverSIP.syslogger_ready?
          # User logs.
          method_str = "
            def log_#{level}(msg)
              return false if @@threshold > #{level_value} || @@congested
              begin
                unless @@logger_mq.trysend ::OverSIP::Logger.syslog_user_msg2str(#{level_value}, msg, log_id), 0
                  @@congested = true
                  ::EM.add_timer(1) do
                    @@logger_mq.trysend ::OverSIP::Logger.syslog_user_msg2str(4, \"logger message queue was full, some logs have been lost\", log_id), 1
                    @@congested = false
                  end
                end
              rescue ::Errno::EMSGSIZE
                @@logger_mq.trysend ::OverSIP::Logger.syslog_user_msg2str(4, \"too long message could not be logged\", log_id), 1 rescue nil
              rescue ::Exception => e
                @@logger_mq.trysend ::OverSIP::Logger.syslog_user_msg2str(4, \"unexpected logging error (\#{e.class}: \#{e.message})\", log_id), 1 rescue nil
              end
            end
          "

          self.module_eval method_str
        end

      end  # .each
    end

    # Generate nice log messages. It accepst three parameters:
    # - level_value: Integer representing the log level.
    # - msg: the String or Exception to be logged.
    # - log_id: a String helping to identify the generator of this log message.
    def self.syslog_system_msg2str(level_value, msg, log_id)
      case msg
      when ::String
        level_value.to_s << "<" << log_id << "> " << msg
      when ::Exception
        "#{level_value}<#{log_id}> #{msg.message} (#{msg.class })\n#{(msg.backtrace || [])[0..3].join("\n")}"
      else
        level_value.to_s << "<" << log_id << "> " << msg.inspect
      end
    end

    def self.syslog_user_msg2str(level_value, msg, log_id)
      case msg
      when ::String
        level_value.to_s << "<" << log_id << "> [user] " << msg
      when ::Exception
        "#{level_value}<#{log_id}> [user] #{msg.message} (#{msg.class })\n#{(msg.backtrace || [])[0..3].join("\n")}"
      else
        level_value.to_s << "<" << log_id << "> [user] " << msg.inspect
      end
    end

    def self.fg_system_msg2str(level, msg, log_id)
      case msg
      when ::String
        "#{level.upcase}: <#{log_id}> " << msg
      when ::Exception
        "#{level.upcase}: <#{log_id}> #{msg.message} (#{msg.class })\n#{(msg.backtrace || [])[0..3].join("\n")}"
      else
        "#{level.upcase}: <#{log_id}> " << msg.inspect
      end
    end

    def self.close
      @@logger_mq.close rescue nil
      @@logger_mq.unlink rescue nil
    end

    # Default logging identifier is the class name. If log_id() method is redefined by the
    # class including this module, or it sets @log_id, then such a value takes preference.
    def log_id
      @log_id ||= (self.is_a?(::Module) ? self.name.split("::").last : self.class.name)
    end

  end  # module Logger

end
