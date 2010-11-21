#!/usr/bin/ruby
#
# A Ruby client library for memcached (memory cache daemon)
#
# == Synopsis
#
#   require 'memcache'
#
#   cache = MemCache::new '10.0.0.15:11211',
#                        '10.0.0.15:11212',
#                        '10.0.0.17:11211:3', # weighted
#                        :debug => true,
#                        :c_threshold => 100_000,
#                        :compression => false,
#                        :namespace => 'foo',
#                        :readbuf_size => 4096
#   cache.servers += [ "10.0.0.15:11211:5" ]
#   cache.c_threshold = 10_000
#   cache.compression = true
#
#   # Cache simple values with simple String or Symbol keys
#   cache["my_key"] = "Some value"
#   cache[:other_key] = "Another value"
#
#   # ...or more-complex values
#   cache["object_key"] = { 'complex' => [ "object", 2, 4 ] }
#
#   # ...or more-complex keys
#   cache[ Time::now.to_a[1..7] ] ||= 0
#
#   # ...or both
#   cache[userObject] = { :attempts => 0, :edges => [], :nodes => [] }
#
#   val = cache["my_key"]               # => "Some value"
#   val = cache["object_key"]           # => {"complex" => ["object",2,4]}
#   print val['complex'][2]             # => 4
#
# == Notes
#
# * Symbols are stringified currently because that's the only way to guarantee
#   that they hash to the same value across processes.
#
#
# == Known Bugs
#
# * If one or more memcacheds error when asked for 'map' or 'malloc' stats, it
#   won't be possible to retrieve them from any of the other servers,
#   either. This is due to the way that the client handles server error
#   conditions, and needs rethinking.
#
#
# == Authors
#
# * Michael Granger <ged@FaerieMUD.org>
#
# Thanks to Martin Chase, Rick Bradley, Robert Cottrell, and Ron Mayer for peer
# review, bugfixes, improvements, and suggestions.
#
#
# == Copyright
#
# Copyright (c) 2003-2005 The FaerieMUD Consortium. All rights reserved.
#
# This module is free software. You may use, modify, and/or redistribute this
# software under the same terms as Ruby.
#
#
# == Subversion Id
#
#  $Id: memcache.rb 86 2005-09-29 05:21:52Z ged $
#

require 'enumerator'
require 'io/reactor'
require 'socket'
require 'sync'
require 'timeout'
require 'uri'
require 'zlib'

begin
	lib_require :Core, 'data_structures/ordered_map'
rescue NoMethodError
	require 'data_structures/ordered_map'
end

### A Ruby implementation of the 'memcached' client interface.
class MemCache
	include Socket::Constants
	
	Log = Struct.new(:server, :time, :type);
	class Log
		def query
			type.to_s
		end
		
		def to_s()
			format(%Q{%s [%.3f msec] %s}, (server.kind_of?(Fixnum) ? "<#{server} servers>" : server), time * 1000, query);
		end
	end

	### Class constants
	# :stopdoc:

	# SVN Revision
	SVNRev = %q$Rev: 86 $

	# SVN Id
	SVNId = %q$Id: memcache.rb 86 2005-09-29 05:21:52Z ged $

	# Default compression threshold.
	DefaultCThreshold = 8_000

	# Default memcached port
	DefaultPort = 11211

	# Default 'weight' value assigned to a server.
	DefaultServerWeight = 1

	# Minimum percentage length compressed values have to be to be preferred
	# over the uncompressed version.
	MinCompressionRatio = 0.80

	# The default number of incoming bytes to read at a time, per socket.
	DefaultReadBufferSize = 4096

	# Default constructor options
	DefaultOptions = {
		:debug			=> false,
		:c_threshold	=> DefaultCThreshold,
		:compression	=> true,
		:namespace		=> nil,
		:readonly		=> false,
		:urlencode		=> false,
		:readbuf_size	=> DefaultReadBufferSize,
		:delete_only	=> false,
		:timeout		=> 1.5,
		:retry_delay	=> 600,
	}

	# Storage flags
	F_SERIALIZED = 1
	F_COMPRESSED = 2
	F_ESCAPED    = 4
	F_NUMERIC	 = 8

	# Line-ending
	CRLF = "\r\n"

	# Flags to use for the BasicSocket#send call. Note that Ruby's socket
	# library doesn't define MSG_NOSIGNAL, but if it ever does it'll be used.
	SendFlags = 0
	SendFlags |= Socket.const_get( :MSG_NOSIGNAL ) if
		Socket.const_defined?( :MSG_NOSIGNAL )

	# Patterns for matching against server error replies
	GENERAL_ERROR		 = /\AERROR\r\n/
	CLIENT_ERROR		 = /\ACLIENT_ERROR\s+([^\r\n]+)\r\n/
	SERVER_ERROR		 = /\ASERVER_ERROR\s+([^\r\n]+)\r\n/
	ANY_ERROR			 = Regexp::union( GENERAL_ERROR, CLIENT_ERROR, SERVER_ERROR )

	# Callables to convert various part of the server stats reply to appropriate
	# object types.
	StatConverters = {
		:__default__	=> lambda {|stat| Integer(stat) },
		:version		=> lambda {|stat| stat }, # Already a String
		:rusage_user	=> lambda {|stat|
			seconds, microseconds = stat.split(/:/, 2)
			microseconds ||= 0
			Float(seconds) + (Float(microseconds) / 1_000_000)
		},
		:rusage_system	=> lambda {|stat|
			seconds, microseconds = stat.split(/:/, 2)
			microseconds ||= 0
			Float(seconds) + (Float(microseconds) / 1_000_000)
		}
	}

	# :startdoc:


	#################################################################
	###	I N S T A N C E   M E T H O D S
	#################################################################

	### Create a new memcache object that will distribute gets and sets between
	### the specified +servers+. You can also pass one or more options as hash
	### arguments. Valid options are:
	### [<b>:compression</b>]
	###   Set the compression flag. See #use_compression? for more info.
	### [<b>:c_threshold</b>]
	###   Set the compression threshold, in bytes. See #c_threshold for more
	###   info.
	### [<b>:debug</b>]
	###   Send debugging output to the object specified as a value if it
	###   responds to #call, and to $deferr if set to anything else but +false+
	###   or +nil+.
	### [<b>:namespace</b>]
	###   If specified, all keys will have the given value prepended before
	###   accessing the cache. Defaults to +nil+.
	### [<b>:urlencode</b>]
	###   If this is set, all cache keys will be urlencoded. If this is not set,
	###   keys with certain characters in them may generate client errors when
	###   interacting with the cache, but they will be more compatible with
	###   those set by other clients. If you plan to use anything but Strings
	###   for keys, you should keep this enabled. Defaults to +true+.
	### [<b>:readonly</b>]
	###   If this is set, any attempt to write to the cache will generate an
	###   exception. Defaults to +false+.
	### [<b>:timeout</b>]
	###   Specifies the number of floating-point seconds to wait during
	###   communication with memcached server.
	### [<b>:retry_delay</b>]
	###   Specifies delay when server that is marked as dead should be tested
	###   one more time if it is back online.
	### If a +block+ is given, it is used as the default hash function for
	### determining which server the key (given as an argument to the block) is
	### stored/fetched from.
	def initialize( *servers, &block )
		opts = servers.pop if servers.last.is_a?( Hash )
		opts = DefaultOptions.merge( opts || {} )

		@debug			= opts[:debug]

		@c_threshold	= opts[:c_threshold]
		@compression	= opts[:compression]
		@namespace		= opts[:namespace]
		@readonly		= opts[:readonly]
		@urlencode		= opts[:urlencode]
		@timeout		= opts[:timeout]
		@retry_delay	= opts[:retry_delay]
		@readbuf_size	= opts[:readbuf_size]

		@delete_only	= opts[:delete_only]

		@buckets		= nil
		@hashfunc		= block || lambda {|val| val.hash}
		@mutex			= Sync::new

		@reactor		= IO::Reactor::new
		
		@@uuid_counter  = 0
		@@broken_counter = 0

		# Stats is an auto-vivifying hash -- an access to a key that hasn't yet
		# been created generates a new stats subhash
		@stats			= Hash::new {|hsh,k|
			hsh[k] = {:count => 0, :utime => 0.0, :stime => 0.0}
		}
		@stats_callback	= nil
		
		self.servers	= servers
	end


	### Return a human-readable version of the cache object.
	def inspect
		"<MemCache: %d servers/%s buckets: ns: %p, debug: %p, cmp: %p, ro: %p>" % [
			@servers.nitems,
			@buckets.nil? ? "?" : @buckets.nitems,
			@namespace,
			@debug,
			@compression,
			@readonly,
		]
	end


	######
	public
	######

	# The compression threshold setting, in bytes. Values larger than this
	# threshold will be compressed by #[]= (and #set) and decompressed by #[]
	# (and #get).
	attr_accessor :c_threshold
	alias_method :compression_threshold, :c_threshold

	# Turn compression on or off temporarily.
	attr_accessor :compression

	# Debugging flag -- when set to +true+, debugging output will be send to
	# $deferr. If set to an object which supports either #<< or #call, debugging
	# output will be sent to it via this method instead (#call being
	# preferred). If set to +false+ or +nil+, no debugging will be generated.
	attr_accessor :debug

	# The function (a Method or Proc object) which will be used to hash keys for
	# determining where values are stored.
	attr_accessor :hashfunc

	# The Array of MemCache::Server objects that represent the memcached
	# instances the client will use.
	attr_reader :servers

	# The namespace that will be prepended to all keys set/fetched from the
	# cache.
	attr_accessor :namespace

	# Hash of counts of cache operations, keyed by operation (e.g., +:delete+,
	# +:flush_all+, +:set+, +:add+, etc.). Each value of the hash is another
	# hash with statistics for the corresponding operation:
	#   {
	#		:stime	=> <total system time of all calls>,
	#		:utime	=> <total user time> of all calls,
	#		:count	=> <number of calls>,
	#	}
	attr_reader :stats

	# Hash of system/user time-tuples for each op
	attr_reader :times

	# Settable statistics callback -- setting this to an object that responds to
	# #call will cause it to be called once for each operation with the
	# operation type (as a Symbol), and Struct::Tms objects created immediately
	# before and after the operation.
	attr_accessor :stats_callback

	# The Sync mutex object for the cache
	attr_reader :mutex

	# If this is +true+, all keys will be urlencoded before being sent to the
	# cache.
	attr_accessor :urlencode


	### Returns +true+ if the cache was created read-only.
	def readonly?
		@readonly
	end


	### Set the servers the memcache will distribute gets and sets
	### between. Arguments can be either Strings of the form
	### <tt>"hostname:port"</tt> (or "hostname:port:weight"), or
	### MemCache::Server objects.
	def servers=( servers )
		@mutex.synchronize( Sync::EX ) {
			@servers = servers.collect {|svr|
				self.debug_msg( "Transforming svr = %p", svr )

				case svr
				when String
					host, port, weight = svr.split( /:/, 3 )
					weight ||= DefaultServerWeight
					port ||= DefaultPort
					Server::new(host, port.to_i, weight, @timeout, @retry_delay)

				when Array
					host, port = svr[0].split(/:/, 2)
					weight = svr[1] || DefaultServerWeight
					port ||= DefaultPort
					Server::new(host, port.to_i, weight, @timeout, @retry_delay)

				when Server
					svr

				else
					raise TypeError, "cannot convert %s to MemCache::Server" %
						svr.class.name
				end
			}

			@buckets = nil
		}

		return @servers			# (ignored)
	end


	### Returns +true+ if there is at least one active server for the receiver.
	def active?
		not @servers.empty?
	end
	
	def close
		@servers.each { |server|
			server.close
		}
	end

	### Fetch and return the values associated with the given +key+ from the
	### cache. Calls associated block if it is not found and stores result with
	### specified +exptime+.
	def get_or_set( key, exptime=0 )
		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "exptime more than 30 days in future" if exptime > Constants::MONTH_IN_SECONDS
		hash = nil

		@mutex.synchronize( Sync::SH ) {
			hash = self.fetch( :get, key )
		}

		if (hash.nil? || !hash.has_key?(key))
			value = yield
			self.set( key, value, exptime )
			return value
		else
			return hash[key]
		end
	end


	### Fetch and return the values associated with the given +keys+ from the cache.
	### Returns +nil+ for any value that wasn't in the cache.
	def get( *keys )
		raise MemCacheError, "no active servers" unless self.active?
		hash = nil

		@mutex.synchronize( Sync::SH ) {
			hash = self.fetch( :get, *keys )
		}

		return *({}.values_at(*keys)) if hash.nil?
		return *(hash.values_at( *keys ))
	end
	alias_method :[], :get

	### Fetch and return the values associated the the given +keys+ from the
	### cache as a Hash object. Returns +nil+ for any value that wasn't in the
	### cache.
	def get_hash( *keys )
		raise MemCacheError, "no active servers" unless self.active?
		return @mutex.synchronize( Sync::SH ) {
			self.fetch( :get_hash, *keys )
		}
	end

	### Fetch and return the values associated with the given +keys+ from the
	### cache. If a value isn't in the cache it will create it with the specified exptime
	### if a block is given. Returns +nil+ for any value that wasn't in the cache or created.'
	def load(prefix, keys, exptime, &block)
		if (keys.kind_of?(Array))
			retval = Hash.new
			keys.each_slice(256) { |key_slice|
				results = real_load(prefix, key_slice, exptime, block)
				retval.merge!(results)
			}
			return retval
		else
			return real_load(prefix, keys, exptime, block)
		end
	end
	
	### Called by #load, but only a slice of keys at a time.
	### This is because we generally call #load from Cacheable, and expect
	### to yield to a block that does a MySQL query.  MySQL hates it if you
	### try to retrieve too many ids (especially multi-part ids) by doing a
	### WHERE clause like "WHERE id = ? OR id = ? or id = ? OR ...".
	def real_load(prefix, keys, exptime, block)
		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "exptime more than 30 days in future" if exptime > Constants::MONTH_IN_SECONDS

		hash = nil
		single_result = false

		unless (keys.kind_of?(Array))
			keys = [[keys]];
			single_result = true;
		end
		
		fullkeys = {};
		keys.each {|key|
			fullkeys[key] = "#{prefix}-#{key.join('/')}";
		}

		@mutex.synchronize( Sync::SH ) {
			hash = self.fetch( :get, *fullkeys.values );
		}

		# process if no server is available
		# NOTE: possible some special handling in the given block
		hash = {} if hash.nil?

		if (block)
			# store all missed keys
			missing_keys = {}
			fullkeys.each_key {|key|
				missing_keys[key] = nil if hash[fullkeys[key]] == nil
			}

			# call the block (with missing keys) to insert values
			if (!missing_keys.empty?)
				backup_keys = missing_keys.dup
				missing_keys = block.call(missing_keys)
				# Extract those keys we cared enough about to ask for
				found_keys = Hash.new
				backup_keys.each { |key, value|
					if (missing_keys.has_key?(key))
						found_keys[key] = missing_keys[key]
					else
						raise "not array" unless key.kind_of? Array
						key_as_string = key.map { |elem| elem.to_s }
						found_keys[key] = missing_keys[key_as_string]
					end
				}

				# prepare keys to insert into memcache
				set_vals = {}
				found_keys.each{ |key, value|
					if (key)
						set_vals[fullkeys[key]] = value;
						hash[fullkeys[key]] = value;
					end
				}

				# insert missing keys into memcache
				set_many(set_vals, exptime) unless set_vals.empty?
			end
		end

		return hash[fullkeys[keys.first]] if (single_result)
		return hash
	end

	### Fetch, delete, and return the given +keys+ atomically from the cache.
	#def take( *keys )
	#	raise MemCacheError, "no active servers" unless self.active?
	#	raise MemCacheError, "readonly cache" if self.readonly?
	#
	#	hash = @mutex.synchronize( Sync::EX ) {
	#		self.fetch( :take, *keys )
	#	}
	#
	#	return hash[*keys]
	#end


	### Unconditionally set the entry in the cache under the given +key+ to
	### +value+, returning +true+ on success. The optional +exptime+ argument
	### specifies an expiration time for the tuple, in seconds relative to the
	### present if it's less than 60*60*24*30 (30 days), or as an absolute Unix
	### time (E.g., Time#to_i) if greater. If +exptime+ is +0+, the entry will
	### never expire.
	def set( key, val, exptime=0 )
		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "readonly cache" if self.readonly?
		raise MemCacheError, "exptime more than 30 days in future" if exptime > Constants::MONTH_IN_SECONDS

		rval = @mutex.synchronize( Sync::EX ) {
			self.store( :set, {key => val}, exptime )
		}
		return (rval.nil? ? nil: rval[key] == true)
	end


	### Multi-set method; unconditionally set each key/value pair in
	### +pairs+. Since this is done async and in parallel, it is more
	###  efficient than doing them individually.
	def set_many( pairs, exptime=0 )
		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "readonly cache" if self.readonly?
		raise MemCacheError,
			"expected an object that responds to the #each_pair message" unless
			pairs.respond_to?( :each_pair )
		raise MemCacheError, "exptime more than 30 days in future" if exptime > Constants::MONTH_IN_SECONDS

		pairs.each_slice(10240) { |pair_slice|
			@mutex.synchronize( Sync::EX ) {
				self.store( :set, pair_slice, exptime )
			}
		}
	end


	### Index assignment method. Supports slice-setting, e.g.:
	###   cache[ :foo, :bar ] = 12, "darkwood"
	### This uses #set_many internally if there is more than one key, or #set if
	### there is only one.
	def []=( *args )
		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "readonly cache" if self.readonly?

		# Use #set if there's only one pair
		if args.length <= 2
			self.set( *args )
		else
			# Args from a slice-style call like
			#   cache[ :foo, :bar ] = 1, 2
			# will be passed in like:
			#   ( :foo, :bar, [1, 2] )
			# so just shift the value part off, transpose them into a Hash and
			# pass them on to #set_many.
			vals = args.pop
			vals = [vals] unless # Handle [:a,:b] = 1
				vals.is_a?( Array ) && args.nitems > 1
			pairs = {}
			[ args, vals ].transpose.each {|k,v| pairs[k] = v}

			self.set_many( pairs )
		end

		# It doesn't matter what this returns, as Ruby ignores it for some
		# reason.
		return nil
	end


	### Like #set, but only stores the tuple if it doesn't already exist.
	def add( key, val, exptime=0 )
		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "readonly cache" if self.readonly?
		raise MemCacheError, "exptime more than 30 days in future" if exptime > Constants::MONTH_IN_SECONDS

		rval = @mutex.synchronize( Sync::EX ) {
			self.store( :add, {key => val}, exptime )
		}
		return (rval.nil? ? nil: rval[key] == true)
	end


	### Like #set, but only stores the tuple if it already exists.
	def replace( key, val, exptime=0 )
		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "readonly cache" if self.readonly?
		raise MemCacheError, "exptime more than 30 days in future" if exptime > Constants::MONTH_IN_SECONDS

		rval = @mutex.synchronize( Sync::EX ) {
			self.store( :replace, {key => val}, exptime )
		}
		return (rval.nil? ? nil: rval[key] == true)
	end


	### Atomically add a tuple if it doesn't already exist, and return
	### true if succeeded, false if the tuple already existed.
	### Note that we do NOT permit setting a specific value.
	def check_and_add( key, exptime=0 )
		raise MemCacheError, "exptime more than 30 days in future" if exptime > Constants::MONTH_IN_SECONDS
		# Generate a uuid that's very likely to be unique between calls.
		@@uuid_counter += 1
		uuid = "Check-#{Process::pid}:#{Time.now.to_f}::#{@@uuid_counter}"
		# Add the key, but don't overwrite it if it already exists.
		check_add = add(key, uuid, exptime)
		# Were we able to add it?
		check_get = get(key)

		# first validate that add and get were successfull
		return nil if (check_add.nil? || check_get.nil?)

		# check condition
		return check_get == uuid
	end


	### Atomically increment the value associated with +key+ by +val+. Returns
	### +nil+ if the value doesn't exist in the cache, or the new value after
	### incrementing if it does. +val+ should be zero or greater.  Overflow on
	### the server is not checked.  Beware of values approaching 2**32.
	def incr( key, val=1 )
		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "readonly cache" if self.readonly?

		@mutex.synchronize( Sync::EX ) {
			self.incrdecr( :incr, key, val )
		}
	end


	### Like #incr, but decrements. Unlike #incr, underflow is checked, and new
	### values are capped at 0.  If server value is 1, a decrement of 2 returns
	### 0, not -1.
	def decr( key, val=1 )
		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "readonly cache" if self.readonly?

		@mutex.synchronize( Sync::EX ) {
			self.incrdecr( :decr, key, val )
		}
	end

	class DeleteLog < Log
		attr_reader :keys, :flags, :exptime
		def initialize(server, time, type, keys, exptime)
			super(server, time, type)
			@keys = keys
			@exptime = exptime
		end
		
		def query
			format("%s, Keys: %s, Expire: %i",
				   super(), keys.join(", "), exptime)
		end
	end

	### Delete the entry with the specified key, optionally at the specified
	### +time+.
	def delete( key, time=nil )
		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "readonly cache" if self.readonly?

		svr = nil

		res = @mutex.synchronize( Sync::EX ) {
			svr = self.get_server( key )
			cachekey = self.make_cache_key( key )

			self.add_stat( :delete ) {
				cmd = "delete %s%s" % [ cachekey, time ? " #{time.to_i}" : "" ]

				start_t = Time.new.to_f
				res = self.send( svr => cmd )
				diff_t = Time.new.to_f - start_t

				message = DeleteLog.new(svr, diff_t, "delete", [key], time)
				$log.debug(message, :memcache)

				res
			}
		}

		# this should NEVER happen
		if res.nil?
			this_method = (caller[0] =~ /`([^']*)'/ and $1)
			$log.error("Invalid internal nil response in #{this_method}!", :memcache)
			return false
		end

		# validate if key was removed
		return res[svr].cmd?("DELETED\r\n", 0) if res[svr]
		return false

	rescue MemCacheNoServerError
		return nil
	end

	def delete_many( *keys )
		raise "This does not work"
		
		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "readonly cache" if self.readonly?

		svr = nil
		map = {}

		res = @mutex.synchronize( Sync::EX ) {
			self.add_stat( :delete ) {
				# Map the key's server to the command to fetch its value
				keys.each { |key|
					svr = self.get_server( key )
					ckey = self.make_cache_key( key )
					map[ svr ] ||= []
					map[ svr ] << "delete " + ckey
				}

				start_t = Time.new.to_f
				res = self.send( map )
				diff_t = Time.new.to_f - start_t

				message = DeleteLog.new((map.length == 1 ? svr : map.length), diff_t, "delete_many", keys, 0)
				$log.debug(message, :memcache)

				res
			}
		}

		# this should NEVER happen
		if res.nil?
			this_method = (caller[0] =~ /`([^']*)'/ and $1)
			$log.error("Invalid internal nil response in #{this_method}!", :memcache)
			return 0
		end

		count = 0
		res.each {|svr, reply|
			count += reply.cmd_count("DELETED\r\n") if reply
		}
		return count

	rescue MemCacheNoServerError
		return nil
	end


	### Mark all entries on all servers as expired.
	def flush_all
		return nil if (@delete_only)

		raise MemCacheError, "no active servers" unless self.active?
		raise MemCacheError, "readonly cache" if self.readonly?

		res = @mutex.synchronize( Sync::EX ) {

			# Build commandset for servers that are alive
			servers = @servers.select {|svr| svr.alive? }
			cmds = self.make_command_map( "flush_all", servers )

			# Send them in parallel
			self.add_stat( :flush_all ) {
				self.send( cmds )
			}
		}

		# this should NEVER happen
		if res.nil?
			this_method = (caller[0] =~ /`([^']*)'/ and $1)
			$log.error("Invalid internal nil response in #{this_method}!", :memcache)
			return false
		end

		# find any nil reply or not OK one
		!res.find {|svr, reply| reply.nil? or !reply.cmd?("OK\r\n", 0)}

	rescue MemCacheNoServerError
		return nil
	end
	alias_method :clear, :flush_all


	### Return a hash of statistics hashes for each of the specified +servers+.
	def server_stats( servers=@servers )
		return nil if (@delete_only)

		# Build commandset for servers that are alive
		asvrs = servers.select {|svr| svr.alive?}
		cmds = self.make_command_map( "stats", asvrs )

		# Send them in parallel
		self.add_stat( :server_stats ) do
			self.send( cmds ) do |svr,reply|
				self.parse_stats( reply )
			end
		end

	rescue MemCacheNoServerError
		return nil
	end


	### Reset statistics on the given +servers+.
	def server_reset_stats( servers=@servers )
		return nil if (@delete_only)

		# Build commandset for servers that are alive
		asvrs = servers.select {|svr| svr.alive? }
		cmds = self.make_command_map( "stats reset", asvrs )

		# Send them in parallel
		res = self.add_stat( :server_reset_stats ) do
			self.send( cmds )
		end

		# this should NEVER happen
		if res.nil?
			this_method = (caller[0] =~ /`([^']*)'/ and $1)
			$log.error("Invalid internal nil response in #{this_method}!", :memcache)
			return false
		end

		# find any nil reply or not OK one
		!res.find {|svr, reply| reply.nil? or !reply.cmd?("RESET\r\n", 0)}

	rescue MemCacheNoServerError
		return nil
	end


	### Return memory maps from the specified +servers+ (not supported on all
	### platforms)
	def server_map_stats( servers=@servers )
		return {} if (@delete_only)

		# Build commandset for servers that are alive
		asvrs = servers.select {|svr| svr.alive? }
		cmds = self.make_command_map( "stats maps", asvrs )

		# Send them in parallel
		self.add_stat( :server_map_stats ) do
			self.send( cmds ) {|s,r| r.to_s }
		end

	rescue MemCacheNoServerError
		return nil
	end


	### Return malloc stats from the specified +servers+ (not supported on all
	### platforms)
	def server_malloc_stats( servers=@servers )
		return {} if (@delete_only)

		# Build commandset for servers that are alive
		asvrs = servers.select {|svr| svr.alive? }
		cmds = self.make_command_map( "stats malloc", asvrs )

		# Send them in parallel
		self.add_stat( :server_malloc_stats ) do
			self.send( cmds ) do |svr,reply|
				self.parse_stats( reply )
			end
		end

	rescue MemCacheNoServerError
		return nil
	end


	### Return slab stats from the specified +servers+
	def server_slab_stats( servers=@servers )
		return {} if (@delete_only)

		# Build commandset for servers that are alive
		asvrs = servers.select {|svr| svr.alive? }
		cmds = self.make_command_map( "stats slabs", asvrs )

		# Send them in parallel
		self.add_stat( :server_slab_stats ) do
			self.send( cmds ) do |svr,reply|
				### :TODO: I could parse the results from this further to split
				### out the individual slabs into their own sub-hashes, but this
				### will work for now.
				self.parse_stats( reply )
			end
		end

	rescue MemCacheNoServerError
		return nil
	end


	### Return item stats from the specified +servers+
	def server_item_stats( servers=@servers )
		return {} if (@delete_only)

		# Build commandset for servers that are alive
		asvrs = servers.select {|svr| svr.alive? }
		cmds = self.make_command_map( "stats items", asvrs )

		# Send them in parallel
		self.add_stat( :server_stats_items ) do
			self.send( cmds ) do |svr,reply|
				self.parse_stats( reply )
			end
		end

	rescue MemCacheNoServerError
		return nil
	end


	### Return item size stats from the specified +servers+
	def server_size_stats( servers=@servers )
		return {} if (@delete_only)

		# Build commandset for servers that are alive
		asvrs = servers.select {|svr| svr.alive? }
		cmds = self.make_command_map( "stats sizes", asvrs )

		# Send them in parallel
		self.add_stat( :server_stats_sizes ) do
			self.send( cmds ) do |svr,reply|
				reply.to_s.sub( /#{CRLF}END#{CRLF}/, '' ).split( /#{CRLF}/ )
			end
		end

	rescue MemCacheNoServerError
		return nil
	end



	#########
	#protected
	#########

	### Create a hash mapping the specified command to each of the given
	### +servers+.
	def make_command_map( command, servers=@servers )
		Hash[ *([servers, [command]*servers.nitems].transpose.flatten) ]
	end


	### Parse raw statistics lines from a memcached 'stats' +reply+ and return a
	### Hash.
	def parse_stats( reply )
		reply = reply.to_s

		# Trim off the footer
		self.debug_msg "Parsing stats reply: %p" % [reply]
		reply.sub!( /#{CRLF}END#{CRLF}/, '' )

		# Make a hash out of the other values
		pairs = reply.split( /#{CRLF}/ ).collect {|line|
			stat, name, val = line.split(/\s+/, 3)
			name = name.to_sym
			self.debug_msg "Converting %s stat: %p" % [name, val]

			if StatConverters.key?( name )
				self.debug_msg "Using %s converter: %p" %
					[ name, StatConverters[name] ]
				val = StatConverters[ name ].call( val )
			else
				self.debug_msg "Using default converter"
				val = StatConverters[ :__default__ ].call( val )
			end

			self.debug_msg "... converted to: %p (%s)" % [ val, val.class.name ]
			[name,val]
		}

		return Hash[ *(pairs.flatten) ]
	end



	### Get the server corresponding to the given +key+.
	def get_server( key )
		@mutex.synchronize( Sync::SH ) {
			if @servers.length == 1
				self.debug_msg( "Only one server: using %p", @servers.first )
				return @servers.first if @servers.first.alive?
		    else

				# If the key is an integer, it's assumed to be a precomputed hash
				# key so don't bother hashing it. Otherwise use the hashing function
				# to come up with a hash of the key to determine which server to
				# talk to
				hkey = nil
				if key.is_a?( Integer )
					hkey = key
				else
					hkey = @hashfunc.call( key )
				end

				# Set up buckets if they haven't been already
				unless @buckets
					@mutex.synchronize( Sync::EX ) {
						# Check again after switching to an exclusive lock
						unless @buckets
							@buckets = []
							@servers.each_index do |idx|
								svr = @servers[idx]
								svr.weight.times { @buckets.push(idx) }
								self.debug_msg( "Adding %d buckets for %p", svr.weight, svr )
							end
						end
					}
				end

				# Fetch a server for the given key, retrying if that server is
				# offline, extract server from matching bucket, if it fails
				# then we move through server list from the one selected
				idx = @buckets[ hkey % @buckets.nitems ]
				@servers.length.times do |offset|
					# check offset server, remember about size of servers list
					i = (idx + offset) % @servers.length
					return @servers[i] if @servers[i].alive?
					self.debug_msg( "Skipping dead server %p", @servers[i] )
				end
			end
		}

		# no available server found
		if (@no_servers_log.nil? || @no_servers_log < Time.now.to_i)
			@no_servers_log = Time.now.to_i + @retry_delay
			$log.critical("No memcached servers available", :memcache)
		end

		raise MemCacheNoServerError, "No memcached servers available"
	end

	class StoreLog < Log
		attr_reader :keys, :exptime
		def initialize(server, time, type, keys, exptime) # keys is a hash key => length
			super(server, time, type)
			@keys = keys
			@exptime = exptime
		end
		
		def query
			str = super()
			keys.each{|key, len| str << ", Key: #{key} => Len: #{len}" }
			str << ", Expire: #{exptime}"
			return str
		end
	end

	### Store the specified key => value pairs to the cache with the expiration time +exptime+.
	def store( type, pairs, exptime )
		raise MemCacheError, "exptime more than 30 days in future" if exptime > Constants::MONTH_IN_SECONDS
		return nil if (@delete_only)

		# Questionable Behavior: Is this line the right thing to do?
		# Removing it doesn't change client behaviour, since the client
		# will just check mysql next time since nil indicates no result.
		del_keys = []
		pairs.delete_if { |k, v|
			del_keys << k if(v.nil?)
			v.nil?
		}
		self.delete_many(*del_keys) if del_keys.length > 0
		return if pairs.length == 0

		svr = nil
		map = {}
		storelog = {}

		res = @mutex.synchronize( Sync::EX ) {
			self.add_stat( type ) {
				# Map the key's server to the command to fetch its value
				pairs.each { |key, val|
					svr = self.get_server( key )
					ckey = self.make_cache_key( key )

					sval, flags = self.prep_value( val )

					map[ svr ] ||= []
					map[ svr ] << "%s %s %d %d %d\r\n%s" % [ type, ckey, flags, exptime, sval.length, sval ]

					storelog[ckey] = sval.length
				}

				start_t = Time.new.to_f
				res = self.send( map )
				diff_t = Time.new.to_f - start_t

				message = StoreLog.new(svr, diff_t, type, storelog, exptime)
				$log.debug(message, :memcache)

				res
			}
		}

		# this should NEVER happen
		if res.nil?
			this_method = (caller[0] =~ /`([^']*)'/ and $1)
			$log.error("Invalid internal nil response in #{this_method}!", :memcache)
			return {}
		end

		# Return true for all keys if everything was successfull
		# To provide per key true/false we have to check how to associate server
		# replies with keys, no such information is present in reply

		not_stored = res.find {|svr, reply|
			reply.nil? or !reply.cmds?("STORED\r\n")
		}

		# some or all operations were not successfull
		return {} if !not_stored.nil?

		rval = {}
		pairs.each {|key, _| rval[key] = true}
		return rval

	rescue MemCacheNoServerError
		return nil
	end

	class FetchLog < Log
		attr_reader :keys
		attr_reader :positive
		def initialize(server, time, type, keys, positive)
			super(server, time, type)
			@keys = keys
			@positive = positive
		end
		
		def query
			format(%Q{%s (%s) Keys: %s}, super(), positive ? "+" : "-", keys.join(','))
		end
	end

	### Fetch the values corresponding to the given +keys+ from the cache and
	### return them as a Hash. If result is nil then we failed to contact any
	### memcache server.
	def fetch( type, *keys )
		return {} if (@delete_only)
		# Make a hash to hold servers => commands for the keys to be fetched,
		# and one to match cache keys to user keys.
		map = Hash::new {|hsh,key| hsh[key] = 'get'}
		cachekeys = {}

		res = {}
		self.add_stat( type ) {

			# Map the key's server to the command to fetch its value
			keys.each do |key|
				svr = self.get_server( key )

				ckey = self.make_cache_key( key )
				cachekeys[ ckey ] = key
				map[ svr ] << " " + ckey
			end
			
			if ($site.config.environment == :dev)
				start = Time.now.to_f
				found = []
			end

			# Send the commands and map the results hash into the return hash
			self.send( map, true ) do |svr, reply|
				if ($site.config.environment == :dev)
					diff = Time.now.to_f - start
					found_this = []
				end

				# No reply or exception (server already marked dead)
				next if reply.empty?

				# check if reply has correct END tag
				if !reply.cmd?("END\r\n", -1)
					$log.error("Malformed reply from #{svr}", :memcache)
					next
				end

				# Iterate over the replies, stripping first the 'VALUE
				# <cachekey> <flags> <len>' line with a regexp and then the data
				# line by length as specified by the VALUE line.
				reply.blocks.each {|v|
					if v.cmd[0]=='V'[0]
						ckey, flags, len = v.ckey,v.flags,v.len
						data = v.data
						rval = self.restore( data[0,len], flags )
						res[ cachekeys[ckey] ] = rval
						found_this << cachekeys[ckey] if ($site.config.environment == :dev)
					end
				}

				if ($site.config.environment == :dev)
					$log.trace(FetchLog.new((map.length == 1 ? svr : map.length), diff, type, found_this, true), :memcache)
					found += found_this
				end
			end

			if ($site.config.environment == :dev)
				diff = Time.now.to_f - start
				map.each {|svr, keys|
					missed = keys.chomp.split(" ").map{|i| cachekeys[i] }.compact - found
					if (!missed.empty?)
						$log.trace(FetchLog.new((map.length == 1 ? svr : map.length), diff, type, missed, false), :memcache)
					end
				}
			end
		}
		return res

	rescue MemCacheNoServerError
		return nil
	end

	### Increment/decrement the value associated with +key+ on the server by
	### +val+.
	def incrdecr( type, key, val )
		return nil if (@delete_only)

		svr = self.get_server( key )
		cachekey = self.make_cache_key( key )

		# Form the command, send it, and read the reply
		res = self.add_stat( type ) {
			cmd = "%s %s %d" % [ type, cachekey, val ]
			self.send( svr => cmd )
		}

		# this should NEVER happen
		if res.nil?
			this_method = (caller[0] =~ /`([^']*)'/ and $1)
			$log.error("Invalid internal nil response in #{this_method}!", :memcache)
			return nil
		end

		# De-stringify the number if it is one and return it as an Integer, or
		# nil if it isn't a number.
		if /^(\d+)/.match( res[svr].to_s )
			return Integer( $1 )
		else
			return nil
		end

	rescue MemCacheNoServerError
		return nil
	end


	### Prepare the specified value +val+ for insertion into the cache,
	### serializing and compressing as necessary/configured.
	def prep_value( val )
		sval = nil
		flags = 0
		
		# Remove the promise wrapper
		val = demand(val)

		# Serialize if something other than a String, Numeric
		case val
		when String
			sval = val.dup
		when Integer
			sval = val.to_s
			flags |= F_NUMERIC
		else
			self.debug_msg( "Serializing %p", val )
			sval = Marshal::dump( val )
			flags |= F_SERIALIZED
		end

		# Compress if compression is enabled, the value exceeds the
		# compression threshold, and the compressed value is smaller than
		# the uncompressed version.
		if @compression && sval.length > @c_threshold
			zipped = Zlib::Deflate::deflate( sval, Zlib::BEST_SPEED )
			if zipped.length < (sval.length * MinCompressionRatio)
				self.debug_msg "Using compressed value (%d/%d)" %
					[ zipped.length, sval.length ]
				sval = zipped
				flags |= F_COMPRESSED
			end
		end

		# Urlencode unless told not to
		#unless !@urlencode
		#	sval = URI::escape( sval )
		#	flags |= F_ESCAPED
		#end

		return sval, flags
	end


	### Escape dangerous characters in the given +string+ using URL encoding
	def uri_escape( string )
		#return URI::escape( sval )
		return string.gsub( /(?:[\x00-\x20]|%[a-f]{2})+/i ) do |match|
			match.split(//).collect {|char| "%%%02X" % char[0]}.join
		end
	end


	### Restore the specified value +val+ from the form inserted into the cache,
	### given the specified +flags+.
	def restore( val, flags=0 )
		self.debug_msg( "Restoring value %p (flags: %d)", val, flags )
		rval = val.dup

		# De-urlencode
		if (flags & F_ESCAPED).nonzero?
			rval = URI::unescape( rval )
		end

		# Decompress
		if (flags & F_COMPRESSED).nonzero?
			rval = Zlib::Inflate::inflate( rval )
		end

		# Unserialize
		if (flags & F_SERIALIZED).nonzero?
			rval = Marshal::load( rval )
		end

		if (flags & F_NUMERIC).nonzero?
			rval = rval.to_i
		end

		return rval

	# Handle all conversion errors
	rescue Object

		@@broken_counter += 1

		# Generate unique key
		key = "Broken-#{Process::pid}:#{Time.now.to_f}::#{@@broken_counter}"
		# Store the value for reference
		self.store(:set, {key => val}, Constants::MONTH_IN_SECONDS)
		$log.warning("KNOWN ISSUE NEX-1714: Exception on memcache key restore", :memcache)
		$log.warning("Saving data that caused exception '#{$!}' at '#{key}'", :memcache)
		# I suspect we are only ever getting here if we have F_COMPRESSED data.
		# r8150, by Nathan on 2007-05-11, took out url_encoding of values, and
		# this would typically happen with compressed data.  I hypothesize that
		# the lack of escaping of compressed data is breaking stuff.  I am
		# sure that compressing the values saves us a bit, but far better that
		# the code works than that it is efficient.  However, at the moment,
		# I do not have enough information to tell if this is what is going on.
		# Note that it is entirely possible we have TWO bugs related to
		# NEX-1714, as the logs seem to show one with 'undefined class/module '
		# with messed up class/module names, and the other with 'class Object
		# needs to have method `_load`', which seems likely to be different.
		flags_set = Array.new
		flags_set << 'F_ESCAPED'    if (flags & F_ESCAPED).nonzero?
		flags_set << 'F_COMPRESSED' if (flags & F_COMPRESSED).nonzero?
		flags_set << 'F_SERIALIZED' if (flags & F_SERIALIZED).nonzero?
		flags_set << 'F_NUMERIC'    if (flags & F_NUMERIC).nonzero?
		$log.warning("Flags set: #{flags_set.join(', ')}", :memcache)
		# Not deleting original key as at this point we don't know it

		# pretend that key does not exist
		return nil
	end


	### Statistics wrapper: increment the execution count and processor times
	### for the given operation +type+ for the specified +server+.
	def add_stat( type )
		raise LocalJumpError, "no block given" unless block_given?

		# Time the block
		starttime = Process::times
		res = yield
		endtime = Process::times

		# Add time/call stats callback
		@stats[type][:count] += 1
		@stats[type][:utime]  += endtime.utime - starttime.utime
		@stats[type][:stime]  += endtime.stime - starttime.stime
		@stats_callback.call( type, starttime, endtime ) if @stats_callback

		return res
	end


	### Write a message (formed +sprintf+-style with +fmt+ and +args+) to the
	### debugging callback in @debug, to $stderr if @debug doesn't appear to be
	### a callable object but is still +true+. If @debug is +nil+ or +false+, do
	### nothing.
	def debug_msg( fmt, *args )
		return unless @debug

		if @debug.respond_to?( :call )
			@debug.call( fmt % args )
		elsif @debug.respond_to?( :<< )
			@debug << "#{fmt}\n" % args
		else
			$deferr.puts( fmt % args )
		end
	end


	### Create a key for the cache from any object. Strings are used as-is,
	### Symbols are stringified, and other values use their #hash method.
	def make_cache_key( key )
		ck = @namespace ? "#@namespace:" : ""

		case key
		when String, Symbol, Fixnum
			ck += key.to_s
		else
			raise MemCache::InternalError, "Attempt to use an invalid object type as a key #{key.class.name}.";
		end

		if(@urlencode)
			ck = uri_escape( ck )
		elsif(ck[' '])
			raise MemCache::InternalError, "Attempt to use a key with a <space>.";
		elsif(ck["\n"])
			raise MemCache::InternalError, "Attempt to use a key with a <new-line>.";
		end

		self.debug_msg( "Cache key for %p: %p", key, ck )
		return ck
	end


	### Socket IO Methods

	### Given +pairs+ of MemCache::Server objects and Strings or Arrays of
	### commands for each server, do multiplexed IO between all of them, reading
	### single-line responses.
	def send( pairs, multiline=false )
		self.debug_msg "Send for %d pairs: %p", pairs.length, pairs
		raise TypeError, "type mismatch: #{pairs.class.name} given" unless
			pairs.is_a?( Hash )
		buffers = {}
		rval = {}

		# Fetch the Method object for the IO handler
		handler = self.method( :handle_line_io )

		# Check if servers are available
		pairs.delete_if {|server,_|
			unless (server.alive?)
				rval[server] = nil
				return true
			end
		}

		# Set up the buffers and reactor for the exchange
		pairs.each do |server,cmds|
			cmds = [*cmds]

			# Handle either Arrayish or Stringish commandsets
			wbuf = cmds.join( CRLF )
			self.debug_msg( "Created command %p for %p", wbuf, server )
			wbuf += CRLF

			# Make a buffer tuple (read/write) for the server
			buffers[server] = { :rbuf => MemCache::RecvBuffer::new(cmds.length), :wbuf => wbuf }

			# Register the server's socket with the reactor
			@reactor.register(server.socket, :write, :read, :error,
				server, buffers[server], multiline, &handler)
		end

		# Do all the IO at once
		self.debug_msg( "Reactor starting for %d IOs", @reactor.handles.length )

		# All exceptions are handled in reactor event handler and are handled
		# on per server socket basis. You will get all available results.

		begin
			# Execute as long as there is at least one event in @timeout time
			stamp = Time.new.to_f
			while !@reactor.empty? && Time.new.to_f - stamp < @timeout
				stamp = Time.new.to_f if @reactor.poll(@timeout) > 0
			end
		rescue Object
			# cleaning after exception is handled below
			$log.error("Exception (#{$!.class}) during poll", :memcache)

			# NOTE: we can may try to make something more elaborate:
			# * detect socket in reactor that actually died and clean it
		end

		# handle unfinished sockets
		# NOTE: this uses io-reactor internal hash from to extract server
		# associated with specific socket that "timeout"
		if (!@reactor.empty?)
			$log.error("Query execution timeout, dead or overloaded server(s)", :memcache)
			@reactor.handles.each_value {|handle|
				srv, _ = handle[:args]

				# validate that we have server object
				next unless srv.instance_of?(MemCache::Server)

				# mark server response as empty
				rval[srv] = nil
				pairs.delete(srv)

				srv.mark_dead("execution timeout")
			}
			@reactor.clear
		end

		self.debug_msg( "Reactor finished." )

		# Build the return value, delegating the processing to a block if one
		# was given.
		pairs.each {|server,cmds|

			# Handle protocol errors if they happen.
			# Action depends on specific protocol error, we log this
			# aprioprately and return invalid server response -> nil
			if buffers[server][:rbuf].error?
				self.handle_protocol_error(buffers[server][:rbuf].to_s, server)
				rval[server] = nil
				next
			end

			# If the caller is doing processing on the reply, yield each buffer
			# in turn. Otherwise, just use the raw buffer as the return value
			if block_given?
				self.debug_msg( "Yielding value/s %p for %p",
					buffers[server][:rbuf].to_s, server ) if @debug
				rval[server] = yield( server, buffers[server][:rbuf] )
			else
				rval[server] = buffers[server][:rbuf]
			end
		}

		return rval
	end


	### Handle an IO event +ev+ on the given +sock+ for the specified +server+,
	### expecting single-line syntax (i.e., ends with CRLF).
	def handle_line_io( sock, ev, server, buffers, multiline=false )
		self.debug_msg( "Line IO (ml=%p) event for %p: %s: %p - %p",
						multiline, sock, ev, server, buffers )

		case ev
		when :read
			buffers[:rbuf] << sock.sysread( @readbuf_size )
 			self.debug_msg "Read %d bytes." % [ buffers[:rbuf].to_s.length ] if @debug
 			if (buffers[:rbuf].done?)
				self.debug_msg "Done with read for %p: %p", sock, buffers[:rbuf] if @debug
				@reactor.remove( sock )
			end

		when :write
			res = sock.send( buffers[:wbuf], SendFlags )
			self.debug_msg( "Wrote %d bytes.", res ) if @debug
			buffers[:wbuf].slice!( 0, res ) unless res.zero?

			# If the write buffer's done, then we don't care about writability
			# anymore, so clear that event.
			if buffers[:wbuf].empty?
				self.debug_msg "Done with write for %p" % sock if @debug
				@reactor.disableEvents( sock, :write )
			end

		when :error
			so_error = sock.getsockopt( SOL_SOCKET, SO_ERROR )
 			self.debug_msg "Socket error on %p: %s" % [ sock, so_error ]

			# clear buffers to correctly handle results handling
			buffers[:rbuf].blocks.clear
			buffers[:wbuf].replace("")

			@reactor.remove( sock )
			server.mark_dead( so_error )

		else
			raise ArgumentError, "Unhandled reactor event type: #{ev}"
		end
	# this handles exceptions that happens during event handling
	# we have to ensure that buffers are invalidated for current server
	# NOTE: operation is not retried on different server
	rescue
		$log.error("Exception (#{$!.class}) during #{ev} event on #{server} server", :memcache)

		# clear buffers to correctly handle results handling
		buffers[:rbuf].blocks.clear
		buffers[:wbuf].replace("")

		@reactor.remove( sock )
		server.mark_dead( $!.message )
	end


	### Handle error messages defined in the memcached protocol. The +buffer+
	### argument will be parsed for the error type, and, if appropriate, the
	### error message.
	def handle_protocol_error( buffer, server )

		case buffer
		when MemCache::GENERAL_ERROR
			$log.error("Unknown protocol command", :memcache)
		when MemCache::CLIENT_ERROR
			$log.error("Client protocol error: #{$1}", :memcache)
		when MemCache::SERVER_ERROR
			$log.error("Server (#{server}) protocol error: #{$1}", :memcache)
		else
			$log.error("Unknown internal error", :memcache)
			server.mark_dead("unknown protocol error");
		end
	end



	#####################################################################
	###	I N T E R I O R   C L A S S E S
	#####################################################################

	### A Multiton datatype to represent a potential memcached server
	### connection.
	class Server

		#############################################################
		###	I N S T A N C E   M E T H O D S
		#############################################################

		### Create a new MemCache::Server object for the memcached instance
		### listening on the given +host+ and +port+, weighted with the given
		### +weight+.
		def initialize(host, port, weight, timeout, retry_delay)
			if host.nil? || host.empty?
				raise ArgumentError, "Illegal host %p" % host
			elsif port.nil? || port.to_i.zero?
				raise ArgumentError, "Illegal port %p" % port
			end

			@host	 = host
			@port	 = port
			@weight	 = weight

			@timeout = timeout
			@retry_delay = retry_delay

			@sock	 = nil
			@retry	 = nil
			@status	 = "not yet connected"
			
	 		# Attempt to resolve NEX-1243 where queue runners seemed to be
			# using each others' memcache instances and getting confused.
			@pid = nil
		end


		######
		public
		######

		# The host the memcached server is running on
		attr_reader :host

		# The port the memcached is listening on
		attr_reader :port

		# The weight given to the server
		attr_reader :weight

		# The Time of next connection retry if the object is dead.
		attr_reader :retry

		# A text status string describing the state of the server.
		attr_reader :status

		# The number of (floating-point) seconds before a connection fails.
		attr_reader :timeout

		# The number of (floating-point) seconds to wait before another
		# connection attemptis made
		attr_reader :retry_delay

		### Return a string representation of the server object.
		def inspect
			return "<MemCache::Server: %s:%d [%d] (%s)>" % [
				@host,
				@port,
				@weight,
				@status,
			]
		end
		def to_s
			return "<%s:%d>" % [ @host, @port ]
		end


		### Test the server for aliveness, returning +true+ if the object was
		### able to connect. This will cause the socket connection to be opened
		### if it isn't already.
		def alive?
			return !self.socket.nil?
		end
		
		def close
			@sock.close unless !@sock
			@sock = nil
		end


		### Try to connect to the memcached targeted by this object. Returns the
		### connected socket object on success; sets @dead and returns +nil+ on
		### any failure.
		def socket
			
			# Connect if not already connected
			if (@pid.nil? || (@pid != Process.pid) || !@sock || @sock.closed?)

				# If the host was dead, don't retry for a while
				if @retry
					return nil if @retry > Time::now
				end

				# Attempt to connect,
				begin
					@sock = Timeout::timeout(@timeout) {TCPSocket::new(@host, @port)}
					@status = "connected"
					@pid = Process.pid
				rescue SystemCallError, SocketError, IOError, TimeoutError
					self.mark_dead($!.message)
				end
			end

			return @sock
		end


		### Mark the server as dead and close its socket. The specified +reason+
		### will be used to construct an appropriate status message.
		def mark_dead( reason="Unknown error" )
			@sock.close if @sock && !@sock.closed?
			@sock = nil
			@pid = nil
			@retry = Time::now + @retry_delay
			@status = "DEAD: %s: Will retry at %s" %
				[ reason, @retry ]

			$log.info("Marking server #{self} dead, reason: #{reason}", :memcache)
		end


	end # class Server


	### Message block class -- represents a single message returned by the
	### memcached.
	class MsgBlock

		### Create a new message block for the given +command+.
		def initialize( command )
			@cmd = command
			@ckey = nil
			@flags = 0
			@len = 0
			@data = ''
		end


		######
		public
		######

		# The command part of the message
		attr_accessor :cmd

		# The cache key for this message (VALUE messages only)
		attr_accessor :ckey

		# The flags associated with this message (VALUE messages only)
		attr_accessor :flags

		# The expected length of the message block (VALUE messages only)
		attr_accessor :len

		# The payload of the block
		attr_accessor :data


		### Set the data block values en masse.
		def set_data_block_vals( ckey, flags, len )
			@ckey  = ckey
			@flags = flags
			@len   = len
			@data  = ""
		end


		### Return the message block as a String
		def to_s
			return @cmd + ( @data ? @data : "" )
		end

	end # class MsgBlock


	### Receive buffer class -- collects incoming data into MemCache::MsgBlocks
	class RecvBuffer

		### Create a new RecvBuffer
		def initialize(num_needed)
			@blocks            = []
			@unparsed_data     = ''
			@data_bytes_needed = 0
			@num_results_needed= num_needed
			@error             = false
		end


		######
		public
		######

		# The blocks that have been parsed so far
		attr_accessor :blocks

		# The data that has not yet been appended to a block
		attr_accessor :unparsed_data

		# The number of bytes left to finish the current block
		attr_accessor :data_bytes_needed

		# The MemCache::MsgBlock that is currently being filled
		attr_accessor :current_block

		# The error condition flag
		attr_writer :error


		### Append the given +data+ to the buffer, creating MsgBlock objects for
		### each command.
		def <<( data )

			if @data_bytes_needed >= data.length
				@current_block.data << data
				@data_bytes_needed -= data.length
				return self
			end

			if @data_bytes_needed > 0
				@current_block.data << data.slice!( 0 .. @data_bytes_needed - 1 )
				@data_bytes_needed = 0
			end

			@unparsed_data << data

			while @data_bytes_needed == 0 && @unparsed_data.gsub!( /\A([^\r]*\r\n)/, '' )
				cmd = $1

				@current_block = MemCache::MsgBlock::new( cmd )
				@blocks << @current_block

				case cmd
				when /\AVALUE (\S+) (\d+) (\d+)\r\n\Z/
					ckey, flags, len = $1, $2.to_i, $3.to_i
					@current_block.set_data_block_vals(ckey, flags, len)
					if @current_block.len >= 1
						@current_block.data = @unparsed_data.slice!(0..@current_block.len-1)
					else
						@current_block.data = ''
					end
					@data_bytes_needed = @current_block.len - @current_block.data.length

				when /\A\r\n\Z/,  # expected between value statements
					/\ASTAT /  # expected to have multiple stats
					# no-op

				else
					# we expect blank lines after value blocks; but if I
					# understand the protocol right, any other responses
					# except VALUE and STAT indicates that the response
					# is complete.
					@num_results_needed -= 1
					@error = true if cmd =~ /\A\S*ERROR/
				end
			end
		end

		### Returns +true+ if the receive buffer has reached the end of input
		### data
		def done?
			if @num_results_needed < 0
				$log.error("Received more data than expected from memcached", :memcache)
				return true
			else
				return @num_results_needed == 0
			end
		end


		### Returns +true+ if the receive buffer has parsed an error response in
		### the input data.
		def error?
			return @error
		end

		### Returns +true+ if receive buffer is empty
		def empty?
			return @blocks.empty?
		end

		### Return the receive buffer as a String
		def to_s
			return @blocks.map{|x| x.to_s }.join + @unparsed_data
		end

		### Return +true+ if certain block +idx+ contains specified command
		def cmd?(value, idx)
			return @blocks[idx].cmd == value if @blocks[idx]
			return false
		end

		### Return count of blocks that contains specified command
		def cmd_count(value)
			count = 0
			@blocks.each {|block| count += 1 if block.cmd == value}
			return count
		end

		### Return +true+ if all blocks contains specified command
		def cmds?(value)
			return false if @blocks.empty?
			@blocks.each {|block| return false if block.cmd != value}
			return true
		end

		#########
		#protected
		#########

		### Output a debugging message depicting the current state of the buffer
		### to $deferr.
		def debug
			$deferr.puts "[ parsed blocks\n  %s\n]" % [
				@blocks.collect {|b|
					"blk => %p : %p" % [ b.cmd, b.data ]
				}.join("\n  "),
				"  unparsed_data => %p" % [ @unparsed_data ],
			]
		end
	end



	#################################################################
	###	E X C E P T I O N   C L A S S E S
	#################################################################

	### Base MemCache exception class
	class MemCacheError < ::Exception; end

	### MemCache server failures - handled specially.
	class MemCacheNoServerError < ::Exception; end

	### MemCache internal error class -- instances of this class mean that there
	### is some internal error either in the memcache client lib or the
	### memcached server it's talking to.
	class InternalError < MemCacheError; end
end # class MemCache
