
lib_require :Core, 'sql', 'sql/mysql-native/mysql'

# mysql implementation of the sql stuff
class SqlDBmysql < SqlBase
	attr :db
	attr :connection_time
	attr :last_query_duration

	#takes options in the form:
	# options = { :host => 'localhost', :login => 'test', :passwd => 'test', :db => 'test',
	#               :transactions => false, :seqtable => 'usercounter' }
	#   options can also include debug options as specified in SqlBase
	def initialize(name, idx, dbconfig)
		options = dbconfig.options;
		@server   = options[:host];
		@port     = options[:port];
		@user     = options[:login];
		@password = options[:passwd];
		@dbname   = options[:db];
		@seq_table = options[:seqtable];

		@persistency = options[:persistency] || false;

		@transactions = options[:transactions] || false;
		@seqtable =  options[:seqtable] || false;

		@timeout = 10;     # number of seconds a connection may be inactive before being reset
		@max_retries = 10; # number of attempts to connect to a db before giving up

		@db = nil;
		@in_transaction = false;

		@last_query_duration = nil
		@last_query_time = nil;
		@connection_creation_time = nil;
		@connection_time = 0;

		# process queries as "streams of data" (use_result)
		@is_query_streamed = false

		super(name, idx, dbconfig);
	end

	def to_s
		return @server + ':' + @dbname;
	end

	#Connect to the db if needed. Connections are generally created at first use
	def connect()
		# check for recent connection
		return true if (@db && (Time.now.to_f - @last_query_time) < @timeout)

		# close previous connection if present
		close()

		# try to connect
		retries = 0
		begin
			# connect and setup connection
			@db = Mysql.real_connect(@server, @user, @password, @dbname, @port)
			@db.real_query("SET collation_connection = 'latin1_swedish_ci'") if @db
		rescue Object
			# check if we should bootstrap, this code probably does not work
			if (@all_options[:bootstrap] && $!.error =~ /Unknown database/ && retries == 0)
				self.bootstrap(*@all_options[:bootstrap])
				retry;
			end

			# raise exception if retries does not help
			if (retries >= @max_retries)
				raise ConnectionError.new($!.error, $!.errno) if $!.kind_of?(MysqlError)
				raise ConnectionError.new($!.message)
			end

			# wait between 50 and 250ms (going up each retry)
			sleep((retries + 1) * ((rand(200)+50)/1000.0));

			# retry
			$log.warning("Failed to connect to #{@server}:#{@dbname}, reconnecting.", :sql)
			retries += 1
			retry
		end

		unless (@db.nil?)
			# set last_query_time here, as it is used to tell if a connection has timed out
			@last_query_time = @connection_creation_time = Time.now.to_f

			$log.trace("Connected to #{@server}:#{@dbname}", :sql)
			return true
		else
			# this should never happen
			$log.error("No database after connect to #{@server}:#{@dbname}", :sql)
			return false
		end
	end

	#This creates the database and creates its tables based on those from the config and database specified.
	def bootstrap(config_name, db)
		$log.info "Creating database #{@dbname}.", :sql
		config = ConfigBase.load_config(config_name);
		db_creator = Mysql.real_connect(@server, @user, @password, nil, @port)
		db_creator.create_db(@dbname)
		db_creator.select_db(@dbname)
		bootstrap_db = config.class.get_dbconfigs(config.class.config_name) { |name, idx, dbconf|
			if (name == db)
				dbconf.create(name, idx);
			else
				nil
			end
		}[db]
		bootstrap_db.list_tables.each {|row|
			db_creator.query(bootstrap_db.get_split_dbs[0].query("SHOW CREATE TABLE `#{row['Name']}`").fetch['Create Table'])
		}
	end

	# close the connection, commiting if needed
	def close()
		return false unless @db

		# commit pending transaction
		commit() if @in_transaction

		begin
			@db.close()
		rescue Mysql::Error
		ensure
			@db = nil
		end

		@connection_time += Time.now.to_f - @connection_creation_time;
		@connection_creation_time = 0;
		@last_query_time = 0;

		return true
	end

	def internal_query(prepared)

		#run the query
		retried = false

		begin
			# try to connect
			raise ConnectionError.new("Internal error") unless connect()

			@db.query_with_result = false if @is_query_streamed
			return @db.query(prepared)

		rescue MysqlError => e
			case e.errno
			when Mysql::Error::CR_SERVER_GONE_ERROR, Mysql::Error::CR_SERVER_LOST
				close()

				# check if we already retried
				raise ConnectionError.new(e.error, e.errno) if retried

				# retry query
				$log.warning("#{e.error} (#{e.errno}) on <#{@server}:#{@dbname}>, reconnecting", :sql)
				retried = true
				retry

			when Mysql::Error::CR_COMMANDS_OUT_OF_SYNC
				# try to recover database connection and forward exception
				@db.skip_result()
				raise CommandsSyncError.new(e.error, e.errno, prepared)

			when Mysql::Error::ER_KEY_NOT_FOUND
				raise CannotFindRowError.new(e.error, e.errno, prepared)

			when Mysql::Error::ER_BAD_FIELD_ERROR
				e.error =~ /^Unknown column '([^']+)' in/
				raise CannotFindColError.new(e.error, e.errno, prepared, $1)

			when Mysql::Error::ER_NO_SUCH_TABLE
				raise CannotFindTableError.new(e.error, e.errno, prepared)

			when Mysql::Error::ER_LOCK_WAIT_TIMEOUT, Mysql::Error::ER_LOCK_DEADLOCK
				raise DeadlockError.new(e.error, e.errno, prepared)

			when Mysql::Error::ER_DUP_ENTRY
				raise DuplicationError.new(e.error, e.errno, prepared)

			else
				raise QueryError.new(e.error, e.errno, prepared)
			end
		ensure
			# fallback to default mode if @db is still there
			@db.query_with_result = true if @db
		end
	end
	
	#run a query. Prepare it with the parameters if there are any
	def query(query, *params, &block)
		#prepare if needed
		if(params.length > 0)
			prepared = prepare(query, *params);
		else
			prepared = query;
		end

		start_time = Time.now.to_f;
		result = internal_query(prepared)
		end_time = Time.now.to_f;

		#debug book keeping
		@last_query_duration = end_time - start_time;
		@time += @last_query_duration;
		@last_query_time = end_time;
		@num_queries += 1;
		debug(prepared, @last_query_duration);

		# does the query run SQL_CALC_FOUND_ROWS?
		calcfound = (query =~ /^SELECT\s+(DISTINCT\s+)?SQL_CALC_FOUND_ROWS/);
		if(calcfound)
			calcfound_result = internal_query("SELECT FOUND_ROWS()");
			calcfound = calcfound_result.fetch_row()[0].to_i;
		end

		# process the result object
		result = DBResultMysql.new(self, result, calcfound)
		result.each(&block) if block
		return result
	end

	def query_streamed(query, *params, &block)
		begin
			# execute query and use results
			@is_query_streamed = true
			if block
				result = query(query, *params).use_result()
				return result.each(&block)
			else
				return query(query, *params).use_result()
			end
		ensure
			# set db back to default mode
			# NOTE: we still need to fetch all results or free results
			@is_query_streamed = false
		end
	end

	#start a transaction, assuming this database supports it
	def start()
		if(@transactions)
			@in_transaction = true;
			return query("START TRANSACTION");
		end

		return false;
	end

	#commit the transaction, assuming this database supports it, and one was open
	def commit()
		# don't commit if no connection exists
		if(@transactions && @in_transaction && @db)
			@in_transaction = false;
			return query("COMMIT");
		end

		return false;
	end

	#rollback the transaction, assuming this database supports it, and one was open
	def rollback()
		# Don't rollback if no connection exists.
		# Don't need to be in a transaction to roll back, in case it was left over from a different process
		if(@transactions && @db)
			@in_transaction = false;
			return query("ROLLBACK");
		end

		return false;
	end

	#quote a value
	def quote(val)
		return Mysql.quote(val);
	end

	def get_seq_id(primary_id, area, start = 1)
		if (@seq_table.nil?)
			raise SiteError.new("get_seq_id(#{primary_id}) called with no sequence table defined.")
		end

		result = query("UPDATE #{@seq_table} SET max = LAST_INSERT_ID(max+1) WHERE id = ? && area = ?", primary_id, area);
		seq_id = result.insert_id;

		if (seq_id > 0)
			return seq_id;
		end
		result = query("INSERT IGNORE INTO #{@seq_table} SET max = ?, id = ?, area = ?", start, primary_id, area);
		if (result.affected_rows > 0)
			return start;
		else
            return self.get_seq_id(primary_id, area, start);
        end
	end

	#return information about the tables
	def list_tables()
		return query("SHOW TABLE STATUS");
	end

	# return information about all the columns associated with a table
	def list_fields(table)
		begin
			return query("SHOW FIELDS FROM `#{table}`");
		rescue QueryError
			$log.exception
			raise
		end
	end

	# return information about all of the indexes associated with a table
	def list_indexes(table)
		begin
			return query("SHOW INDEXES FROM `#{table}`");
		rescue QueryError
			$log.exception
			raise
		end
	end


	# the result of a SELECT query from the mysql implementation of the SqlDB class
	class DBResultMysql
		def initialize(db, result, total_rows)
			@db = db; #the db object
			@result = result; #the result object
			@total_rows = total_rows; #if the query had SQL_CALC_FOUND_ROWS, this is the result of that
		end

		def free
			@result.free()
		end

		# Check whether result is empty
		def empty?
			return @result.empty?
		end

		# Check whether there are still pending use_results to fetch
		def pending?
			return !(@result.data? or @result.eof)
		end

		# number of rows in the result set. Equivalent to fetch_set.length
		# possibly should be avoided, as most dbs don't have this function
		def num_rows()
			return @result.num_rows();
		end

		# if the query had SQL_CALC_FOUND_ROWS, this is the result of that, otherwise just num_rows
		def total_rows()
			if(@total_rows)
				return @total_rows;
			else
				return num_rows();
			end
		end

		#number of rows affected by the last query. If another query was run since this one, this will be wrong!
		def affected_rows()
			return @db.db.affected_rows();
		end

		#insert id of the last query. If another query was run since this one, this will be wrong!
		def insert_id()
			return @db.db.insert_id();
		end

		# return one result at a time as a hash
		def fetch
			return @result.fetch_hash()
		end

		# return one result at a time as an array
		# generally only useful for: col1, col2 = fetch_array()
		def fetch_array
			return @result.fetch_row();
		end

		# loop through the associated code block with each row as a hash as the parameter
		# NOTE: if +mutex+ is present then it synchronizes on yield. This variant
		#       may be used to ensure no race condition during parallel blocks execution.
		def each(mutex = nil)
			# restart internal counter
			@result.data_seek(0)

			if mutex
				# yield each row with synchronization
				while (line = @result.fetch_hash())
					mutex.synchronize {yield line}
				end
			else
				# yield each row
				while (line = @result.fetch_hash())
					yield line
				end
			end
		ensure
			# always clear result for use results
			@result.free() if !(@result.data? or @result.eof)
		end

		def collect
			out = []
			while(line = @result.fetch_hash())
				out.push(yield(line))
			end
			out
		end

		# return an array of all the rows as hashes
		def fetch_set()
			results = [];

			while(line = @result.fetch_hash())
				results.push(line);
			end

			return results;
		end

		# return a single field
		# generally only useful for queries that always return exactly one row with one column
		def fetch_field()
			return fetch_array()[0];
		end

		def use_result()
			# validate correct type
			if @result.class != Mysql
				raise SqlBase::ResultError.new("Result already stored/used")
			end

			@result = @result.use_result()
			return self
		end

		def store_result()
			# validate correct type
			if @result.class != Mysql
				raise SqlBase::ResultError.new("Result already stored/used")
			end

			@result = @result.store_result()
			return self
		end
	end
end
