
lib_require :Core, 'sql', 'collect_hash'

#Sql class for balancing queries to distributed servers
class SqlDBStripe < SqlBase
	attr :dbs
	attr :last_query_duration

#side effects:
#-ORDER BY is by server, so could return: 0,2,4,1,3
#-LIMIT is by server, so could return up to (numservers * limit), and of course the offset is useless
#-GROUP BY won't group across servers
#-count(*) type queries (agregates) will return one result per server if it is sent to more than one server


	#takes options in the form:
	# databases = [ { :dbobj => SqlDBmysql, .... },
	#               { :dbobj => SqlDBMirror, ... },
	#                .... ]
	#      dbobj is a reference to a lower level db type, be it a real connection
	#      to the db (SqlDBmysql or SqlDBdbi), or SqlDBMirror
	# splitfunc is a function that takes the results of get_server_values and
	#      translates them to server ids, ie indexes in the @dbs array.
	def initialize(name, idx, dbconfig)
		@dbs = dbconfig.children.collect_hash {|serverid, server| [serverid, server[0]] };
		@id_func = dbconfig.options[:id_func] || :hash;
		@last_query_duration = nil
		@is_query_streamed = false

		super(name, idx, dbconfig);
	end

	def map_servers(ids, writeop)
		return send("map_servers_#{@id_func}", ids.uniq, writeop).flatten.uniq;
	end

	def map_servers_hash(ids, writeop)
		serverids = @dbs.keys.sort;
		return ids.map {|id|
			serverids[id.first.to_i % serverids.length];
		}
	end

	def map_servers_all(ids, writeop)
		return ids.map {|id|
			@dbs.keys;
		}
	end

	def to_s
		dbnames = @dbs.map {|id, db| db.to_s }
		return dbnames.join(',');
	end

	def connect()
	 	# connections are created as needed at query time
	 	return true
	end

	# close the connection
	def close()
		# underlying dbs clean themselves
		@dbs.each {|id, db| db.close()}
		return true
	end

	# return an array of the underlying db handles.
	def get_split_dbs()
		return @dbs.values;
	end

	def num_dbs()
		return @dbs.length;
	end

	# split version of query figures out how to split, then passes it to squery, which actually runs it
	def query(query, *params, &block)
		query = query.gsub(/\s*;*\s*$/, '');
		prepared = prepare(query, *params);

		keys = get_server_values(prepared);

		return squery(keys, prepared, &block);
	end

	def query_streamed(query, *params, &block)
		begin
			# execute query and use results
			@is_query_streamed = true
			return query(query, *params, &block)
		ensure
			# set dbs back to default mode
			@is_query_streamed = false
		end
	end

	# Used for debugging purposes, and designed to be called from inside
	# the console (/nexopia/ruby-run console).  Execute the query across the
	# shards and output the data.
	# Use it, for example, by doing:
	# $site.dbs[:usersdb].exec('SELECT userid, state FROM users WHERE date_of_birth = ?', Date.new(1973, 9, 1))
	# This outputs a list of rows, and returns the row count.
	def exec(sql, *params)
		row_count = 0
		query(sql, *params).each { |row|
			$log.trace row.inspect, :sql
			row_count += 1
		}
		return row_count # Otherwise the console dumps a lot of info.
	end

	#run a query on the servers mapped to by the specified keys.
	# Prepare it with the parameters if there are any
	def squery(keys, query, *params, &block)
		query = query.gsub(/\s*;*\s*$/, '');

		#prepare if needed. Don't accept balance keys through the params
		if(params.length > 0)
			prepared = prepare(query, *params);
			prepkeys = get_server_values(prepared);

			if (prepkeys)
				raise ParamError.new("Don't accept balance keys within the query to squery.")
			end
		else
			prepared = query;
		end

		writeop = (prepared[0,6].upcase != "SELECT")

		# map keys to servers
		if (!keys) # do for all
			# allow select, insert ... select, update, delete, analyze, optomize, alter table
			# disallow single row changing ops with exception of insert ignore
			if (prepared[0,6].upcase == "INSERT")
				if (!(prepared[7,6].upcase == "IGNORE" || prepared.match("SELECT")))
					raise ParamError.new("Cannot INSERT to all dbs, on query: #{prepared}")
				end
			end

			ids = map_servers_all([0], writeop).flatten.uniq
			prepared << " /**: all :**/"
		else
			ids = map_servers([*keys], writeop)
			prepared << " /**: writeop :**/" if writeop
		end

		if (ids.length == 0)
			$log.warning("Query doesn't map to a server: #{prepared}", :sql)
		end

		#run the queries
		start_time = Time.now.to_f;

		results = []
		threads = {}
		exception = nil
		mutex = nil

		ids.each {|id|
			if (!@dbs[id])
				$log.warning("Query attempted to use split server ##{id} on #{self}, which doesn't exist.", :sql)
				next
			end

			# prepare mutex to parallelize block processing
			# NOTE: we do that for blocks as those will execute in parallel
			mutex = Mutex.new if block

			# spawn thread to execute query
			# NOTE: using ruby native implementation does not block on query
			# NOTE: exceptions are stored for each thread separately, we can't
			#       reliably stop all other threads (abort_on_exception stop
			#       *all* threads, not only those we run here).
			threads[id] = Thread.new {
				begin
					# execute streamed or normal query
					result = if @is_query_streamed
						@dbs[id].query_streamed(prepared)
					else
						@dbs[id].query(prepared)
					end

					# process each row using block and mutex
					result.each(mutex, &block) if block

					Thread.current["id"] = id
					Thread.current["result"] = result
				rescue Object
					# save exception to raise it later
					Thread.current["raise"] = $!
				end
			}
		}

		# wait for all threads to finish and check exception status
		threads.each_value {|thread|
			thread.join
			# specific thread finished, store exceptions
			# NOTE: we remember first exception
			exception ||= thread["raise"]
		}

		# process exceptions and clean results
		# NOTE: all threads should finish by this moment
		if exception
			# clean streamed results
			if @is_query_streamed
				threads.each_value {|thread|
					if thread.key?("result") and thread["result"].pending?
						thread["result"].free()
					end
				}
			end

			# forward exception
			raise exception
		end

		# collect results
		results = ids.collect {|id|
			if (threads.has_key?(id))
				threads[id]["result"]
			else
				nil
			end
		}

		# remove nil results
		results.compact!

		end_time = Time.now.to_f;
		@last_query_duration = end_time - start_time;

		return StripeDBResult.new(results);
	end

	#start a transaction
	def start()
		@dbs.each { |id, db| db.start(); }
	end

	#commit a transaction
	def commit()
		@dbs.each { |id, db| db.commit(); }
	end

	#rollback a transaction
	def rollback()
		@dbs.each { |id, db| db.rollback(); }
	end

	#escape a value for this db.
	def quote(str)
		return @dbs.any.quote(str);
	end

	def get_seq_id(id, area, start = false)
		serverid = map_servers([id], true).pop;
		if(serverid)
			return @dbs[serverid].get_seq_id(id, area, start);
		else
			return false;
		end
	end

	#list the tables in this db
	def list_tables()
		return @dbs.any.list_tables();
	end

	# return information about all the columns associated with a table
	def list_fields(table)
		return @dbs.any.list_fields(table);
	end

	# return information about all of the indexes associated with a table
	def list_indexes(table)
		return @dbs.any.list_indexes(table);
	end

	def debug_time=(time)
		@dbs.each {|id, db| db.debug_time = time}
	end

	def num_queries
		num = 0;

		@dbs.each { |id, db|
			num += db.num_queries;
		}

		return num;
	end

	def query_time
		time = 0;

		@dbs.each { |id, db|
			time += db.query_time;
		}

		return time;
	end

	class StripeDBResult
		def initialize(results)
			@results = results;
		end

		# Free all results
		def free
			@results.each {|result| result.free()}
		end

		# Check whether all results are empty
		def empty?
			# stripe result is empty when all underlying result are empty
			@results.each {|result| return false unless result.empty?}
			return true
		end

		# Check whether there are still pending use_results to fetch
		def pending?
			# stripe use pending is true when there is some result left
			@results.each {|result| return true if result.use_pending?}
			return false
		end

		# number of rows in the result set. Equivalent to fetch_set.length
		# possibly should be avoided, as most dbs don't have this function
		def num_rows()
			num = 0
			@results.each {|result| num += result.num_rows()}
			return num
		end

		# if the query had SQL_CALC_FOUND_ROWS, this is the result of that, otherwise just num_rows
		def total_rows()
			num = 0
			@results.each {|result| num += result.total_rows()}
			return num
		end

		#number of rows affected by the last query. If another query was run since this one, this will be wrong!
		def affected_rows()
			num = 0
			@results.each {|result| num += result.affected_rows()}
			return num
		end

		#insert id of the last query. If another query was run since this one, this will be wrong!
		def insert_id()
			if(@results.length != 1)
				raise SiteError, "Cannot insert_id on a multi-server query";
			end

			return @results[0].insert_id();
		end

		# return one result at a time as a hash
		def fetch
			@results.each {|result|
				ret = result.fetch()
				return ret if ret
			}
			return nil
		end

		# return one result at a time as an array
		# generally only useful for: col1, col2 = fetch_array()
		def fetch_array
			@results.each {|result|
				ret = result.fetch_array()
				return ret if ret
			}
			return false
		end

		# loop through the associated code block with each row as a hash as the parameter
		def each(&block)
			# forward each to result
			@results.each {|result| result.each(&block) }
			# mark operation as finished, no break used in block
			if_finished = true
		ensure
			# check if we should cleanup
			# NOTE: this will save us cleaning for all correct queries
			unless if_finished
				# always clear result for use results
				@results.each {|result| result.free() if result.pending?}
			end
		end

		# return an array of all the rows as hashes
		def fetch_set()
			results = [];

			@results.each { |result|
				while(line = result.fetch())
					results.push(line);
				end
			}

			return results;
		end

		# return a single field
		# generally only useful for queries that always return exactly one row with one column
		def fetch_field()
			if(@results.length != 1)
				raise SiteError, "Cannot fetchfield on a multi-db query";
			end

			return @results[0].fetch_field();
		end

		def use_result()
			# validate correct type
			@results.each {|result|
				if @result.class != Mysql
					raise SqlBase::ResultError.new("Result already stored/used")
				end
			}

			@results.collect! {|result| result.use_result()}
			return self
		end

		def store_result()
			# validate correct type
			@results.each {|result|
				if @result.class != Mysql
					raise SqlBase::ResultError.new("Result already stored/used")
				end
			}

			# store results
			@results.collect! {|result| result.store_result()}
			return self
		end
	end
end
