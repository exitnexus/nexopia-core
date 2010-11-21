
lib_require :Core, 'errorlog'
lib_require :Core, 'data_structures/string'
lib_require :Core, 'mutable_time'
lib_require :Core, 'json'

class SqlBase
	attr_reader :all_options;

	# This class is used to construct a database object.
	class Config
		public
		attr :live,true;
		attr :type,true;
		attr :options;
		attr :children,true;
		attr :inherit,true;
		attr :blocks_run,true;
		attr :all_blocks_run,true;

		# Initialize a dbconfig object with either no argument or a hash
		# with the following possible settings:
		#  - :live, whether the config should be automatically instantiated
		#  - :type, a Class object derived from SqlBase that this will be passed
		#           to.
		#  - :options, a hash of type specific options to be used in initializing
		#              the database object.
		#  - :children, a hash of type specific child database objects to be
		#               used by this object.
		#  - :inherit, an existing dbconfig that this inherits from.
		# Note that if you're not putting these through the main config interface,
		#  children have to be manually initialized and inherit will not do anything,
		#  and live will also have no effect.
		def initialize(init = {})
			@live = init[:live] || false;
			@type = init[:type] || SqlDBmysql;
			@options = init[:options] || {}
			@children = init[:children] || {};
			@inherit = init[:inherit] || nil;

			@blocks_run = [];
			@all_blocks_run = [];
		end

		def create(name, idx)
			return @type.new(name, idx, self);
		end

		# note that this is actually a merge, not a replacement.
		def options=(hash)
			@options.merge!(hash);
		end

		# Constructs child configs and passes them out by a yield, then replaces
		# the entries with whatever the yield returns.
		def build_children(dbconfigs)
			@children.each {|key, childblocks|
				if (!childblocks.kind_of?(Array))
					childblocks = [childblocks];
				end
				new_childblocks = [];
				childblocks.each {|childblock|
					# inheritence on a child works like this:
					#  - copy in the parents' options{}
					#  - run the child's block
					#  - if there is an inherit, start over with:
					#   - run the inherit's all_blocks_run
					#   - run the parent's blocks
					#   - run the child's block

					childconfig = Config.new();
					# copy parent's options
					childconfig.options = @options;
					# now we can run the actual childconfig
					childblock.call(childconfig);

					if (childconfig.inherit)
						inherit = dbconfigs[childconfig.inherit];
						childconfig = Config.new();

						# run the inherited from's blocks in their
						# entirety
						inherit.all_blocks_run.each {|block|
							block.call(childconfig);
						}
						# add in the parent's options
						childconfig.options = @options;
						# now run the child's own blocks.
						childblock.call(childconfig);
					end

					# Recurse into the child's child builder
					childconfig.build_children(dbconfigs) {|passback|
						yield(passback);
					}

					new_childblocks.push(yield(childconfig));
				}
				@children[key] = new_childblocks;
			}
		end
	end

	attr :name
	attr :idx

	# options = { :debug_level => 1, :debug_regex => //, :debug_time => 1.0 }
	# debug levels:
	#  0 -> no debug output at all
	#  1 -> log slow and :debug_regex matching queries
	#  2 -> log all queries
	#  3 -> log all queries and explain
	def initialize(name, idx, dbconfig)
		options = dbconfig.options;
		@all_options = options;
		@debug_level = options[:debug_level] || 1
		@debug_time = options[:debug_time] || 1.0
		@debug_regex = options[:debug_regex] || nil
		@max_query_count = 1000; #max queries to be stored for debug

		@connection_creation_time = 0;
		@connection_time = 0;
		@num_queries = 0;
		@time = 0;
		@last_query_time = 0;

		@name = name
		@idx = idx
	end

	# This function is intended to give a recursive view of the database
	# hierarchy. This can be used to generate structured log output.
	# The default implementation returns {to_s => self}, but aggregates
	# should use it to list their child databases.
	def get_struct()
		return {to_s => self};
	end

	attr_writer :debug_time
	attr_reader :num_queries, :query_time;

	# return an array of the underlying db handles. Being a single single connection, this is just for compatability
	def get_split_dbs()
		return [ self ];
	end

	def num_dbs()
		return 1;
	end

	#in the single database case, squery throws away the keys, and uses the database defined query function
	def squery(keys, query, *params, &block)
		query(query, *params, &block)
	end

	#repeat a query until it stops changing stuff
	#generally useful for big updates/deletes that would block for a long time
	def repeat_query(query, limit = 1000)
		begin
			query(query + " LIMIT " + limit);
		end while(affected_rows() == limit);
	end

	# Replace placeholders in query with the parameters,
	# placeholders will be replaced with their escaped equivalent.
	# * strings and symbols will be put into quotes, while ints won't
	# * true/false becomes 'y'/'n'
	# * nil becomes NULL
	# * passing an array as a parameter will put it in as a comma separated list
	#   wrapped with (), arrays may be nested
	# The placeholder # will give the extra comment used for server balancing
	def prepare(query, *params)
		if (query.gsub(/[^#?]/,'').length != params.length)
			raise ParamError.new("Wrong param count on query #{query}: #{params.inspect}")
		end

		prepared_query = query.gsub(/([#?])/) {
			prepare_object(params.shift, ($1 == '#' ? 3 : 0));
		}
		return prepared_query;
	end

	# Extract the keys from a query.
	# This implementation does not edit out the comments from the query.
	# NOTE: we assume that user strings are ONLY in '' quotations
	def get_server_values(query)
		ids = []

		# can we do fast lookup? check if we can fast remove all user strings
		if (query.index(?\\).nil?)
			# remove all strings and find all our comments
			ids = query.gsub(/'[^']*'/, "").scan(/\/\*\*%: ([\d,-]+) :%\*\*\//)

			# extract ids from comments, do not generate new objects
			ids.map! {|match| vals = match[0].split(','); vals.map! {|val| val.to_i}; vals}
			ids.flatten!

		# slower (~2x-4x) but more accurate method
		else
			# initialize loop
			idx = 0
			quote = nil
			regex_chars = /[\/\\'"]/
			regex_keys = /^\/\*\*%: ([\d,-]+) :%\*\*\//

			# look for special characters in loop
			# NOTE: index is faster that each_byte
			while (idx = query.index(regex_chars, idx))
				case query[idx]
				# check if inside quote
				when ?', ?"
					quote = (quote == query[idx]) ? nil : query[idx]
					idx += 1
				# skip escaped character
				when ?\\
					idx += 2
				# check for our comment
				when ?/
					# try match if not inside quoted string
					if quote.nil? && query[idx, query.length] =~ regex_keys
						idx += $&.length
						$1.split(",").each {|val| ids << val.to_i}
					else
						idx += 1
					end
				else
					idx += 1
				end
			end
		end

		# make sure we return only single key
		ids.uniq!

		return ids.empty? ? false : ids
	end

	# wrap a block in a transaction.
	# if a transaction is already open, commit it and start a new one
	# if it fails, roll back
	def transaction()
		commit();
		start();

		begin
			yield self;
		rescue QueryError => e
			return rollback();
		end

		return commit();
	end

	Log = Struct.new(:db, :time, :query, :should_explain, :backtrace);
	class Log
		def to_s()
			format(%Q{%s [%.3f msec] "%s" }, db, time * 1000, query);
		end

		def explain()
			return should_explain && db.query("EXPLAIN #{query}").fetch;
		end
	end

	# called from the query command to log queries if needed
	def debug(query, query_time)

		# process log level
		case @debug_level
		when 0
			return
		when 1
			return unless ( (query_time < @debug_time) ||
				(@debug_regex && query.match(@debug_regex)) )
		when 3
			explain = (query =~ /^SELECT/)
			backtrace = caller
		end

		# process query
		case query
		when /^EXPLAIN/
		when /^(INSERT|UPDATE|DELETE)/
			$log.debug(Log.new(self, query_time, query, explain, backtrace), :sql)
		else
			$log.trace(Log.new(self, query_time, query, explain, backtrace), :sql)
		end
	end

	class SqlError < Exception
		init_log(:error, :sql)

		attr_reader :error
		attr_reader :errno

		def initialize(error, errno = nil)
			@error = error
			@errno = errno
			super(@error)
		end

		def to_s()
			"#{@error}#{" (#{@errno})" if !errno.nil?}"
		end
	end

	class QueryError < SqlError
		attr_reader :query

		def initialize(error, errno = nil, query = nil)
			@query = query
			super(error, errno)
		end

		def to_s()
			"#{@error}#{" (#{@errno})" if !errno.nil?}#{" on query #{@query}" if !query.nil?}"
		end
	end

	class QueryTargetError < QueryError
		attr_reader :target

		def initialize(error, errno = nil, query = nil, target = nil)
			@target = target
			super(error, errno, query)
		end
	end

	class ParamError < SqlError; end
	class ResultError < SqlError; end
	class ConnectionError < SqlError; end
	class DeadlockError < QueryError; end
	class CommandsSyncError < QueryError; end
	class CannotFindRowError < QueryTargetError; end
	class CannotFindColError < QueryTargetError; end
	class CannotFindTableError < QueryTargetError; end
	class DuplicationError < QueryError; end

	private
	#takes an object and turns it to a quoted string form
	#split is a stack type parameter which outputs the split comment if it is > 0
	# it is used to output them only for the first entry in a multi-dimensional array
	def prepare_object(obj, split)
		obj = demand(obj)
		str = case obj
				when Array
					obj = obj.dup;
					obj.each_with_index {|o, i|
						obj[i] = prepare_object(o, (split == 3 ? split - 1 : split - 1 - i));
					}
					split = 0; #never use a full array as the split string
					'(' + obj.join(',') + ')';
				when Integer #ints don't need escaping
					obj.to_s;
				when Float
					obj.to_s;
				when String::NoEscape
					obj.to_s
				when String
					"'" + quote(obj.convertible_to_utf8) + "'";
				when nil
					"NULL";
				when true
					"'y'";
				when false
					"'n'";
				when Symbol
					"'" + quote(obj.to_s) + "'";
				when MutableTime
					obj.to_i.to_s;
				when Date
					"'#{obj.to_s}'";
				when Lazy::Promise
					return prepare_object(demand(obj), split);
				else #try .to_s before failing?
					raise ParamError.new("Trying to escape an unknown object #{obj.class}")
				end
		if(split > 0)
			str << "/**%: #{str} :%**/";
		end
		return str;
	end
end


