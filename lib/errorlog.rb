require 'stringio'

class ErrorLog
	LogLevels = {
		:spam     => 0, # (lowest)
		:trace    => 1,
		:debug    => 2,
		:info     => 3,
		:warning  => 4,
		:error    => 5,
		:critical => 6  # (highest)
	}
end

class Exception
	# setup default target for logging
	def self.init_log(level, facility)
		# basic validation
		raise TypeError if ErrorLog::LogLevels[level].nil?
		raise TypeError unless facility.kind_of?(Symbol)

		methods = %Q{
			def log_level; :#{level}; end
			def facility; :#{facility}; end
		}

		self.class_eval methods
	end

	def log_message
		"#{self.message} (#{self.class.name})"
	end

	# initialize default
	init_log(:error, :general)
end

# Base class for site-specific errors
class SiteError < StandardError
	attr_reader :original

	def initialize(message = nil, original = nil)
		message.nil? ? super() : super(message)
		@original = original unless original.nil?
	end

	def log_message
		original.nil? ? super : "#{super} -> #{original.log_message}"
	end
end

class ErrorLog

	# Describes a log entry ass passed to the log_* functions.
	LogBufferItem = Struct.new('LogBufferItem', :time, :realstr, :level, :facility);

	# pass the target(s) the errorlog should be output to to new(). Defaults
	# to :stderr. Valid values are currently:
	#  :stderr - to stderr
	#  :page - to the currently running page, directly mingled with the output
	#  :syslog - to the syslog daemon on the local machine.
	#  :logfile - to a logfile called logs/site/#{facility}
	#  :logfile_#{something} - to a logfile called logs/site/#{something}
	#  :request_buffer - to a request buffer (see PageRequest#log) called #{facility}
	#  :request_buffer_#{something} - to a request buffer (see PageRequest#log) called #{something}
	def initialize(default_minlevel = :info, facilities = {:general => {:stderr => nil}, :sql => {:sql_logfile => nil, :request_buffer => nil}})
		@colorize_log_output = $config.colorize_log_output
		begin
			require 'text/highlight'
		rescue LoadError
			@colorize_log_output = false
		end

		begin
			require 'syslog'
		rescue LoadError
		end

		@log_levels = {}
		@facilities = facilities
		@targets = [] # to overload targets for a period.
		@default_facility = :general
		@default_minlevel = default_minlevel
		@highlighter = @colorize_log_output && Text::ANSIHighlighter.new

		@debugstderr = nil
		@realstderr = STDERR
		@realstdout = STDOUT.dup()
	end

	# Set up logging for any special cases that we want to track.
	def setup_special_logging
		# Redefine this deprecated method to properly log through our logging mechanism (so
		# that a developer will see it even when in single thread view) and also log a 
		# stacktrace so that we can see where it's coming from. Return object_id, which should
		# be equivalent.
		Object.send :define_method, :id, lambda {
			$log.warning "KNOWN ISSUE NEX-900: Accessing deprecated Object method on class: #{self.class}", :core
			$log.custom_exception :warning, :core, "Object#id is deprecated; use Object#object_id", caller
			return object_id
		}
	end

	def reassert_stderr()
		# this branch reasserts our stderr from within a cgi handler.
		if (@debugstderr)
			STDERR.reopen(@debugstderr);
			$stderr = STDERR;
		end
	end

	def exception(error = $!, backtrace = $@)
		custom_exception(error.log_level, error.facility, error, backtrace)
	end

	# Logs object with backtrace as exception
	# Can handle children of Exception or any other custom objects
	def custom_exception(level, facility, error = $!, backtrace = $@)
		out = StringIO.new

		if (error.respond_to?(:page_request))
			out << ":#{error.page_request.area}#{error.page_request.uri}"
			if (error.page_request.session.user && !error.page_request.session.user.anonymous?)
				out << " suser=#{error.page_request.session.user.username},suid=#{error.page_request.session.user.userid}"
			end
			if (error.page_request.user)
				out << " puser=#{error.page_request.user.username},puid=#{error.page_request.user.userid}"
			end
			out << ": "
		end

		# process error message and backtrace
		if (error.respond_to?(:original) && !error.original.nil?)
			out << "#{error} (#{error.class}) -> #{error.original} (#{error.original.class}\n"
			out << error.original.backtrace.join("\n") unless error.original.backtrace.nil?
		else
			out << "#{error} (#{error.class})\n"
			out << backtrace.join("\n") unless backtrace.nil?
		end

		writelog(out.string, level, facility)
	end

	# Logs a string at the specified level to the configured targets.
	def write(string, level, facility = @default_facility)
		# Ensure that our string is... a string!  There are those of us
		# "true believers" (all hail Michal and Remi) that believe that
		# this should actually read:
		#   raise unless string.kind_of?(String)
		# ... but we have been out-argued by the dark evil known as
		# Castellan and his lazy, slothful ways.
		string = string.to_s.strip
		
		targets = {}
		# Fetch the facilities that we should log this entry to.
		if (@facilities.has_key?(facility))
			targets = @facilities.fetch(facility)
		else
			# Our facility has not been defined in our logging
			# configuration.  If there are also no over-ride logging
			# targets defined in @targets, then use the logging
			# targets for our @default_facility; otherwise leave
			# our result as an empty hash, to be populated by
			# @targets.
			#
			# Note that I am not sure _why_ we don't _always_ log
			# to @default_facility's targets (even if @target is
			# populated), but I do this to safely preserve prior
			# behavior.
			if (@targets.empty?)
				targets = @facilities.fetch(@default_facility, {})
			end
		end

		# Filter out any targets whose configuration prevents them from
		# receiving log entries of this level.
		targets = targets.reject { |target, minlevel| (! minlevel.nil?) && (LogLevels[minlevel] > LogLevels[level]) }
		
		# Convert our remaining hash of logging target => minlevel pairs
		# into a nice array of logging targets.
		targets = targets.keys

		# Append our over-ride logging targets, if we have any.
		if (! @targets.empty?)
			targets = targets + @targets
		end

		targets.uniq.each { |target|
			send("log_#{target}", string, level, facility);
		}
	end

	# Logs a string at the specified level to the configured targets.
	def writelog(string, level = :info, facility = @default_facility)
		# Get the minimum logging level for the given facility.
		# If we haven't already set it, get it from the config.
		minlevel = if( @log_levels[facility].nil? )
			@log_levels[facility] = ($site) ? $site.config.log_minlevel_for(facility) :	@default_minlevel
		else
			@log_levels[facility]
		end
		
		if (level && LogLevels[level] >= LogLevels[minlevel])
			$log.write(string, level, facility)
		end
	end
	
	def determine_facility
		# Try to use the module of the caller.  Note that we
		# imply this based on the directory, which is accurate
		# most of the time.
		if (caller.size > 1)
			caller[1] =~ /\/(\w*)\//
			begin
				facility = $1.downcase.to_sym unless $1.nil?
			rescue
				# No need to do anything
			end
		end
		return facility || @default_facility
	end

	# Logs a string at :spam to the configured targets.
	def spam(string, facility = nil)
		facility = determine_facility if facility.nil?
		# Get the minimum logging level for the given facility.
		# If we haven't already set it, get it from the config.
		minlevel = if( @log_levels[facility].nil? )
			@log_levels[facility] = ($site) ? $site.config.log_minlevel_for(facility) :	@default_minlevel
		else
			@log_levels[facility]
		end
		
		if (LogLevels[:spam] >= LogLevels[minlevel])
			$log.write(string, :spam, facility)
		end
	end

	# Logs a string at :trace to the configured targets.
	def trace(string, facility = nil)
		facility = determine_facility if facility.nil?
		# Get the minimum logging level for the given facility.
		# If we haven't already set it, get it from the config.
		minlevel = if( @log_levels[facility].nil? )
			@log_levels[facility] = ($site) ? $site.config.log_minlevel_for(facility) :	@default_minlevel
		else
			@log_levels[facility]
		end
		
		if (LogLevels[:trace] >= LogLevels[minlevel])
			$log.write(string, :trace, facility)
		end
	end

	# Logs a string at :debug to the configured targets.
	def debug(string, facility = nil)
		facility = determine_facility if facility.nil?
		# Get the minimum logging level for the given facility.
		# If we haven't already set it, get it from the config.
		minlevel = if( @log_levels[facility].nil? )
			@log_levels[facility] = ($site) ? $site.config.log_minlevel_for(facility) :	@default_minlevel
		else
			@log_levels[facility]
		end
		
		if (LogLevels[:debug] >= LogLevels[minlevel])
			$log.write(string, :debug, facility)
		end
	end

	# Logs a string at :info to the configured targets.
	def info(string, facility = nil)
		facility = determine_facility if facility.nil?
		# Get the minimum logging level for the given facility.
		# If we haven't already set it, get it from the config.
		minlevel = if( @log_levels[facility].nil? )
			@log_levels[facility] = ($site) ? $site.config.log_minlevel_for(facility) :	@default_minlevel
		else
			@log_levels[facility]
		end
		
		if (LogLevels[:info] >= LogLevels[minlevel])
			$log.write(string, :info, facility)
		end
	end

	# Logs a string at :warning to the configured targets.
	def warning(string, facility = nil)
		facility = determine_facility if facility.nil?
		# Get the minimum logging level for the given facility.
		# If we haven't already set it, get it from the config.
		minlevel = if( @log_levels[facility].nil? )
			@log_levels[facility] = ($site) ? $site.config.log_minlevel_for(facility) :	@default_minlevel
		else
			@log_levels[facility]
		end
		
		if (LogLevels[:warning] >= LogLevels[minlevel])
			$log.write(string, :warning, facility)
		end
	end

	# Logs a string at :error to the configured targets.
	def error(string, facility = nil)
		facility = determine_facility if facility.nil?
		# Get the minimum logging level for the given facility.
		# If we haven't already set it, get it from the config.
		minlevel = if( @log_levels[facility].nil? )
			@log_levels[facility] = ($site) ? $site.config.log_minlevel_for(facility) :	@default_minlevel
		else
			@log_levels[facility]
		end
		
		if (LogLevels[:error] >= LogLevels[minlevel])
			$log.write(string, :error, facility)
		end
	end

	# Logs a string at :critical to the configured targets.
	def critical(string, facility = nil)
		facility = determine_facility if facility.nil?
		# Get the minimum logging level for the given facility.
		# If we haven't already set it, get it from the config.
		minlevel = if( @log_levels[facility].nil? )
			@log_levels[facility] = ($site) ? $site.config.log_minlevel_for(facility) :	@default_minlevel
		else
			@log_levels[facility]
		end
		
		if (LogLevels[:critical] >= LogLevels[minlevel])
			$log.write(string, :critical, facility)
		end
	end

	# Logs an object's var_get() to the configured targets
	def object(object, level = :debug, facility = nil)
		facility = determine_facility if facility.nil?
		writelog(object.var_get(), level, facility)
	end

	def userstr
		return nil unless(defined? PageRequest) #needed since PageRequest is defined after errorlog is loaded
		req = PageRequest.current
		return nil unless req

		if(evaluated?(req.session))
			return "#{req.session.userid}/#{req.get_ip}"
		else
			return req.get_ip
		end
	end

	#put in constants so they don't get created each time.
	LOG_TIME_FORMAT = "%b %d %y, %H:%M:%S."
	LOG_TIME_FORMAT_MS = "%04i"

	def timestr()
		time = Time.now
		return time.strftime(LOG_TIME_FORMAT) + format(LOG_TIME_FORMAT_MS, ((time.to_f - time.to_i) * 10000))
	end

	def detailed_string(facility, level, string, time = nil, user = nil, pid = Process.pid)
		str = ""
		str << "#{time} "  if time
		str << "[#{user}] " if user
		if $site
			if $site.config_name
				str << "#{$site.config_name}."
			end
			if $site.static_number
				str << "r#{$site.static_number}."
			end
		end
		str << "#{pid}.#{facility}.#{level}"
		str << " (#{PageRequest.top.token})" if Object.const_defined?(:PageRequest) && PageRequest.top
		str << ": #{string}"
		return str
	end

	def colorize(symbol, string)
		return nil unless string
		return "#{@highlighter.foreground($config.colors(symbol))}#{string}#{@highlighter.reset}"
	end

	# Passes the string directly to stderr.
	def log_stderr(realstr, level, facility)
		if (@colorize_log_output)
			realstr = colorize(level, realstr)
			level = colorize(level, level)
			facility = colorize(facility, facility)
			time = colorize(:time, timestr)
			user = colorize(:user, userstr)
			pid = colorize(:pid, Process.pid)
			@realstderr.puts(detailed_string(facility, level, realstr, time, user, pid));
		else
			@realstderr.puts(detailed_string(facility, level, realstr, timestr, userstr));
		end
		begin
			@realstderr.fsync
		rescue
			@realstderr.flush
		end
	end
	
	# Passes the *real* string directly to stdout. Mostly for the dispatch-test
	# script.
	def log_direct(realstr, level, facility)
		if (@realstdout.respond_to?(:raw_puts))
			@realstdout.raw_puts(realstr);
		else
			@realstdout.puts(realstr);
		end
	end

	# Logs to a page being displayed if there is one, otherwise fails.
	def log_page(realstr, level, facility)
		# overridden by definition in pagehandler once it's loaded. See pagerequest.rb
	end

	# Passes the string to syslog at a level mapped to syslog loglevels.
	def log_syslog(realstr, level, facility)
		syslog_level = case level
			when :spam then Syslog::LOG_INFO;
			when :trace then Syslog::LOG_INFO;
			when :debug then Syslog::LOG_INFO;
			when :info then Syslog::LOG_INFO;
			when :warning then Syslog::LOG_WARNING;
			when :error then Syslog::LOG_ERR;
			when :critical then Syslog::LOG_CRIT;
		end
	
		# Re-open our syslog connection if either our identity has changed
		# or if we don't currently have a connection.
		ident = $0.split(" ")[0]
		if ((! @syslog) || (! @syslog.opened?) || (@syslog.ident != ident))
			if (@syslog && @syslog.opened?)
				@syslog.close
			end
			@syslog = Syslog.open(ident, 0, Syslog::LOG_LOCAL1)
		end
	
		@syslog.log(syslog_level | Syslog::LOG_LOCAL1, "%s", detailed_string(facility, level, realstr, nil, userstr));
	end

	# forwards to logfile with the filename the same as facility.
	def log_logfile(realstr, level, facility)
		logfile(facility, realstr, level, facility);
	end

	# forwards to a request buffer with the buffername the same as the facility
	def log_request_buffer(realstr, level, facility)
		request_buffer(facility, realstr, level, facility);
	end

	# Writes to an error log file in the site_base_dir directory.
	def logfile(filename, realstr, level, facility)
		File.open("#{$config.site_base_dir}/logs/site/#{filename}.log", "a") {|logfile|
			logfile.puts(detailed_string(facility, level, realstr, timestr, userstr));
		}
	end

	# Writes to an internal buffer that can be retrieved via the pagerequest
	def request_buffer(buffername, realstr, level, facility)
		# Replaced on load of pagerequest.rb
	end

	# Handles forwarding unkown logfile_* targets to the logfile function.
	def method_missing(name, *args)
		if (matches = /^log_(logfile|request_buffer)_(.*)$/.match(name.to_s))
			send(matches[1].to_sym, matches[2].to_sym, *args);
		else
			super(name, *args);
		end
	end

	# Pass a set of targets to forcefully log to them for the duration of the block
	# passed in. Ie.
	# $log.log_to(:logfile) { $log.info("hello"); }
	def to(*targets)
		targets, @targets = @targets, targets;
		begin
			yield
		ensure
			targets, @targets = @targets, targets;
		end
	end
	
	# get the log level for a particular facility
	def log_minlevel_for(facility)
		
		if( @log_levels[facility].nil? )
			@log_levels[facility] = ($site) ? $site.config.log_minlevel_for(facility) :	@default_minlevel
		else
			@log_levels[facility]
		end # 	if( @log_levels[facility].nil? )
	end
	
	# set the log minlevel for the facilit(ies|y) given to minlevel, unless they're
	# already lower than that (ie. set_log_minlevel_for(:admin, :info) when :admin is
	# set to :debug will leave it at :debug)
	def log_minlevel_lower(facilities, minlevel)
		facilities = [*facilities]
		original_loglevel = {}
		begin
			facilities.each { |facility|
				original_loglevel[facility] = (!@log_levels[facility].nil?) ? @log_levels[facility] : @default_minlevel
				@log_levels[facility] = if (LogLevels[minlevel] < LogLevels[original_loglevel[facility]])
					minlevel
				else
					original_loglevel[facility]
				end
			}
			yield
		ensure
			facilities.each {|facility|
				@log_levels[facility] = original_loglevel[facility]
			}
		end
	end

	# set the log minlevel for the facilit(ies|y) given to minlevel, unless they're
	# already higher than that (ie. set_log_minlevel_for(:admin, :info) when :admin is
	# set to :critical will leave it at :critical)
	def log_minlevel_raise(facilities, minlevel)
		facilities = [*facilities]
		original_loglevel = {}
		begin
			facilities.each {|facility|
				original_loglevel[facility] = (!@log_levels[facility].nil?) ? @log_levels[facility] : @default_minlevel
				@log_levels[facility] = if (LogLevels[minlevel] > LogLevels[original_loglevel[facility]])
					minlevel
				else
					original_loglevel[facility]
				end
			}
			yield
		ensure
			facilities.each {|facility|
				@log_levels[facility] = original_loglevel[facility]
			}
		end
	end
end

