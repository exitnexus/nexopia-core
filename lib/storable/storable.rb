lib_require :Core, "var_dump", "attrs/class_attr", 'storable/column', 'storable/storable_selection', "attrs/enum_attr", "attrs/enum_map_attr", "attrs/bool_attr", "lazy", 'data_structures/ordered_map', 'data_structures/paged_result', 'storable/user_content'
lib_require :Core, 'storable/monitored_content', 'storable/relation_manager', 'storable/storable_proxy', 'storable/storable_id'

require 'set'
require 'mocha'
require 'rexml/document' #needed for dclone

class Hash
	def dclone
		klone = self.clone
		klone.clear
		self.each_key{|k| klone[k.dclone] = self[k].dclone}
		klone
	end
end
class Bignum; def dclone; self; end; end
class NilClass; def dclone; self; end; end
class TrueClass; def dclone; self; end; end;
class FalseClass; def dclone; self; end; end;
class Lazy::Promise; def dclone; self; end; end;

#Storable wraps a single row of a table.  It is intended to be subclassed for each database table in use.
#A basic implementation should be similar to:
#  class SomeTable < Storable
#      init_storable(<database handle>, <table name>);
#
#      def created()
#          ...do something when an object is inserted into the database...
#      end
#
#      def updated()
#          ...do something when an object changes in the database...
#      end
#
#      def deleted()
#         ...do something when an object is deleted from the database...
#      end
#
#      ...the rest of your class here...
#  end
#
#Rows can be retrieved using Storable.find(), limited selections that retrieve only a subset of columns can be defined
#using register_selection().
class Storable
	public

	extend UserContent
	extend MonitoredContent
	
	def self.report(*args)
		$log.error "Falling through to Storable's report method. We should never get here."
		$log.object caller, :error
		#intentionally left blank, just captures and ignores calls to setup reporting
		#when reporter.rb is loaded it extends Scoop::Reporter which overrides this
	end
	
	DEFAULT_PAGE_LENGTH = 25
	
	#valid entries here are :insert, and :update
	attr_accessor(:update_method, :insert_id, :affected_rows, :total_rows, :cache_points, :selection)

	@@subclasses = {};
	@@__cache__ = {};
	#Create a new object. If +set_default+ is true, then initialize all of its 
	#column attributes to the default column values.
	def initialize(set_default = true)

		self.update_method = :insert;
		
		if (set_default)
			
			self.class.columns.each_value {|column|
				# Need to create a brand new Enum for Enum columns because if we use the default_value Enum, only the 
				# pointer to that Enum will be stored in the new object (meaning a change to the new object's value 
				# would affect future default settings).
				# Boolean in our case is a subclass of Enum (due to the 'n', 'y' crap), so it's handled the same way.
				if( column.default_value.kind_of?(Boolean))
					instance_variable_set(column.sym_ivar_name, Boolean.new(column.default_value.symbol));
				elsif(column.default_value.kind_of?(Enum))					
					# Need to check whether we're setting an Enum or EnumMap
					if (self.respond_to?(column.sym_name_ex))
						instance_variable_set(column.sym_ivar_name, EnumMap.new(column.default_value.symbol, column.default_value.map));
					else
						instance_variable_set(column.sym_ivar_name, Enum.new(column.default_value.symbol, column.default_value.symbols));
					end
				else
					instance_variable_set(column.sym_ivar_name, column.default_value);
				end
			}
		end
	end

	#Default prefix is the name of the class.
	def prefix()
		return self.class.prefix;
	end

	def inspect
		fields = self.columns.inject([]) do |retval, (name, column)|
			retval << "#{name}=\"#{instance_variable_get(column.sym_ivar_name)}\""
		end
		return "\#<#{self.class} #{fields.join(", ")}>"
	end

	def to_s
		return "#{self.class} [#{[*self.get_primary_key].join(',')}]"
	end

	#call the getter for an extra column to be added to the cache
	def get_extra_cache_column(column)
		return extra_cache_columns[column][:get].bind(self).call
	end
	#call the setter for an extra column to be added to the cache
	def set_extra_cache_column(column, value)
		return extra_cache_columns[column][:set].bind(self).call(value)
	end
	
	#a hash of column name to original value, it will potentially
	#have missing keys for columns which haven't changed.
	def modified_hash
		@modified_hash ||= {}
	end
	
	#an array of columns that have been modified
	def modified_columns
		#If this is a new object then all columns are modified
		if (self.update_method == :insert)
			return self.columns.keys
		else
			return self.modified_hash.keys.select {|key| self.modified?(key)}
		end
	end

	#Checks to see if column has been modified since it was retrieved from the database.
	#
	# This was changed on Mar 3, 2009 to return true/false values only (with the use of a column)
	#  depending on the existence of the key in the hash. It used to return the value stored in the
	#  hash by that column. This was a column when the stored value was nilClass or false. With modified?
	#  being used entirely in conditionals this caused weird problems. The contents haven't changed, just 
	#  the return value. Code review revealed nothing directly modifying this hash outside of the Storable
	#  subsystem and nothing using the return value of this function for anything more than conditional statements.
	#
	# It is strongly advised that you do not directly modify the modified_hash hash as it could have
	#  weird side effects. If you are experiencing problems with UPDATEs check to make sure the correct
	#  value is returned for the requested column from this function.
	def modified?(column=nil)
		if (column)
			return modified_hash.has_key?(column.to_sym);
		else
			return !modified_hash.values.compact.empty?
		end
	end
	
	#returns a new storable instance in the form that this object had when it was first loaded
	def original_version
		original_version = self.class.new
		self.columns.each_value {|column|
			if (modified?(column.sym_name))
				original_version.instance_variable_set(column.sym_ivar_name, modified_hash[column.sym_name])
			else
				original_version.instance_variable_set(column.sym_ivar_name, instance_variable_get(column.sym_ivar_name))
			end
		}
		return original_version
	end
	
	def hash
		return self.get_primary_key.hash
	end

	def eql?(obj)
		return self.class == obj.class && self == obj
	end
	
	def created?
		return self.update_method != :insert
	end
	
	#Sets every column to report as unmodified.
	def clear_modified!
		@modified_hash.clear if @modified_hash
	end

	def storable_id
		self.class::StorableID.new([*self.get_primary_key], :PRIMARY, self.selection)
	end

	#This function should be overriden in any subclass that can be associated with a ticket
	#It should provide a text representation of that object, particularly any field which may
	#later be changed.
	def ticket_notes
		return "";
	end


	class_attr_accessor(:db, :table, :columns, :seq_initial_value, :enums)

	self.db = "not_a_db";
	self.table = "not_a_table"
	self.seq_initial_value = 1;
	self.enums = {};

	#Save the object to the database.  The attribute update_method is checked to determine how to do this.
	#
	# When using the :duplicate option the operation is considered an update. As such, the before_update and
	#  after_update functions will be called on the object. Since we don't know before hand what operation
	#  we need to assume one of the two operations and update is it. 
	def store(*args)
		if (![:insert, :update].include?(self.update_method))
			raise "Attempted to store #{self} with an invalid update method: #{self.update_method}."
		end

		options = self.class.extract_options_from_args!(args);

		incr_update = if (options[:increment])
			true
		else
			false
		end

		dup_update = if (options[:duplicate] && self.update_method != :update)
			self.update_method = :update
			true
		else
			false
		end

		case update_method
		when :insert
			# run hook and invalidation methods
			before_create()
			unless (options[:nocache])
				self.invalidate_cache_keys(false)
				RelationManager.invalidate_store(self)
			end

			# column with auto increment
			# NOTE: this implies support for only one this type of column
			increment_column = nil
			omit_columns = {}
			result = nil

			begin
				# initialize temporary variables
				variables = []
				cols = ""

				# prepare values to insert
				self.class.columns.each_value {|column|
					# check if we should omit adding this column
					next if omit_columns.has_key?(column.sym_name)

					# setup query part
					if (self.class.split_column?(column.name))
						cols += "`#{column.name}` = #, "
					else
						cols += "`#{column.name}` = ?, "
					end

					# setup corresponding variable
					if (self.respond_to?(column.sym_name_ex))
						variables << self.send(column.sym_name_ex).value
					else
						variables << self.send(column.sym_name)
					end

					if (column.auto_increment?)
						increment_column = column
						options[:insert_id] = true
					end
				}

				# remove trailing characters
				cols.chomp!(", ")

				sql = if (options[:ignore])
					"INSERT IGNORE INTO `#{self.table}` SET #{cols} "
				else
					"INSERT INTO `#{self.table}` SET #{cols} "
				end

				result = self.db.query(sql, *variables)
			rescue SqlBase::CannotFindColError
				# extract column
				column = self.columns[$!.target.to_sym]

				# retry if column was not modified
				unless (column.nil? || self.modified_hash.has_key?(column.sym_name))
					$log.warning("Deleted column '#{column.name}' in '#{self.class.name}' detected, retrying store", :sql)
					omit_columns[column.sym_name] = true
					retry
				else
					raise
				end
			end

			# change update method now as the object is in database
			self.update_method = :update

			# extract auto generated object id
			if (options[:insert_id])
				@insert_id = result.insert_id
				if (increment_column)
					self.send(increment_column.sym_name_eq, @insert_id)
				end
			end

			# update affected rows property
			if (options[:affected_rows])
				@affected_rows = result.affected_rows
			end

			# call hook
			after_create()
		when :update
			# run hook and invalidation methods
			before_update()
			unless (options[:nocache])
				self.invalidate_cache_keys(true)
				RelationManager.invalidate_store(self)
			end

			result = nil
			incr_variables = []
			variables = []
			incr_cols = ""
			cols = ""

			# just run hook if not modified
			unless modified?
				after_update()
				return
			end

			# prepare all modified values
			self.class.columns.each_value {|column|
				# omit columns that didn't change
				next unless self.modified?(column.sym_name)

				# setup query part
				if (self.class.split_column?(column.name))
					cols += "`#{column.name}` = #, "
				else
					cols += "`#{column.name}` = ?, "
				end

				# setup corresponding variable
				if (self.respond_to?(column.sym_name_ex))
					variables << self.send(column.sym_name_ex).value
				else
					variables << self.send(column.sym_name)
				end
			}

			# remove trailing characters
			cols.chomp!(", ")

			if (dup_update)
				if (incr_update)
					self.class.columns.each_value {|column|
						if (options[:increment][0] == column.sym_name)
							incr_cols += "`#{column.name}` = `#{column.name}` + #{options[:increment][1]}, "
						elsif (self.modified?(column.sym_name) && !column.primary)
							# setup query part
							if (self.class.split_column?(column.name))
								incr_cols += "`#{column.name}` = #, "
							else
								incr_cols += "`#{column.name}` = ?, "
							end

							# setup corresponding variable
							if (self.respond_to?(column.sym_name_ex))
								incr_variables << self.send(column.sym_name_ex).value
							else
								incr_variables << self.send(column.sym_name)
							end
						end
					}

					# remove trailing characters
					incr_cols.chomp!(", ")

					# setup variables
					variables = variables + incr_variables
				else
					incr_cols = cols
					variables = variables + variables
				end

				sql = "INSERT INTO `#{self.table}` SET #{cols} ON DUPLICATE KEY UPDATE #{incr_cols}"
			else
				sql = "UPDATE #{self.table} SET #{cols} WHERE "

				primary_key.each {|key|
					# setup query part
					if (self.class.split_column?(key))
						sql << " #{key} = # && "
					else
						sql << " #{key} = ? && "
					end

					# setup corresponding variable
					variables << self.send(:"#{key}")
				}

				if (options[:conditions])
					if (options[:conditions].kind_of?(Array))
						sql << " #{options[:conditions][0]}"
						variables << options[:conditions][1]
					else
						sql << " #{options[:conditions]}"
					end
				end

				# remove trailing characters if present
				sql.chomp!("&& ")
			end

			# execute query
			result = self.db.query(sql, *variables)

			# update affected rows property
			if (options[:affected_rows])
				@affected_rows = result.affected_rows;
			end

			# call hook
			after_update()
		else
			raise "Unsupported update method: #{update_method}"
		end
	end

	def prime_extra_columns
		self.class.extra_cache_columns.each_key {|name|
			self.get_extra_cache_column(name.to_sym)
		}
	end
	
	def _dump(depth)
		values = {}

		if (self.selection)
			self.selection.columns.each_key {|key|
				values[key] = self.instance_variable_get(columns[key].sym_ivar_name)
			}
		else
			self.class.columns.each_value {|column|
				values[column.sym_name] = self.instance_variable_get(column.sym_ivar_name)
			}
		end

		values.each{|k,v|
			values[k] = String.new(v) if (v.kind_of?(UserContent::UserContentString) && v.kind_of?(String))
		}
		self.class.extra_cache_columns.each_key {|name|
			values[name.to_sym] = self.get_extra_cache_column(name.to_sym)
		}
		values[:__update_method__] = self.update_method if(self.update_method != :update)
		values[:__selection__] = self.selection.symbol if(self.selection)

		dump_str = Marshal.dump(values)
		return dump_str
	end
	
	#Delete the object from local cache and the database.
	def delete(*args)
		
		options = self.class.extract_options_from_args!(args);

		case update_method
		when :insert, :update
			# run hook and invalidation methods
			before_delete()
			unless (options[:nocache])
				self.invalidate_cache_keys(false)
				RelationManager.invalidate_delete(self)
			end

			result = nil
			omit_columns = {}

			# NOTE: we omit columns that are removed from table
			# This is basically for cases when table has no primary key. Then
			# all table columns are treated in storable as primary key. We don't
			# distinguish this case at this point
			begin
				variables = []
				cols = ""

				# delete object with primary keys
				sql = "DELETE FROM `#{self.table}` WHERE "

				primary_key.each {|key|
					# check if we should omit adding this column
					next if omit_columns.has_key?(key.to_sym)

					# setup query part
					if (self.class.split_column?(key))
						sql << " `#{key}` = # && "
					else
						sql << " `#{key}` = ? && "
					end

					# setup corresponding variable
					if (self.respond_to?(:"#{key}!"))
						variables << self.send(:"#{key}!").value
					else
						variables << self.send(key)
					end
				}
				
				# remove trailing characters
				sql.chomp!("&& ")

				# execute query
				result = self.db.query(sql, *variables)
			rescue SqlBase::CannotFindColError
				# extract column
				column = self.columns[$!.target.to_sym]

				# retry if column was not modified
				unless (column.nil?)
					$log.warning("Deleted column '#{column.name}' in '#{self.class.name}' detected, retrying delete", :sql)
					omit_columns[column.sym_name] = true
					retry
				else
					raise
				end
			end

			# update affected rows property
			if (options[:affected_rows])
				@affected_rows = result.affected_rows
			end

			# call hook
			after_delete()
		else
			raise "Unsupported update method: #{update_method}";
		end
	end

	def trigger_event_hook(event)
		if (self.class.event_hooks[event])
			self.class.event_hooks[event].each {|hook|
				self.instance_exec(&hook)
			}
		end
	end

	#Called before a new row is inserted into the database.
	def before_create()
		trigger_event_hook(:before_create)
		trigger_event_hook(:before_store)
	end

	#Called after a new row is inserted into the database.
	def after_create()
		trigger_event_hook(:after_create)
		trigger_event_hook(:after_store)
	end

	#Called before a row is updated in the database.
	def before_update();
		trigger_event_hook(:before_store)
		trigger_event_hook(:before_update)
	end
	#Called after a row is updated in the database
	def after_update();
		trigger_event_hook(:after_update)
		trigger_event_hook(:after_store)
	end

	#Called before a row is deleted from the database.
	def before_delete();
		trigger_event_hook(:before_delete)
	end
	#Called after a row is deleted from the database.
	def after_delete();
		trigger_event_hook(:after_delete)
	end

	#Called after a row is loaded from the database.
	def after_load()
		trigger_event_hook(:after_load)
	end

	#Called everytime any column is changed, after the change.
	def on_field_change(column_name)
	end

	def invalidate_cache_keys(use_modification_state)
		if (use_modification_state) #take only modified columns into consideration for invalidation
			self.class.internal_cache.delete_if {|key,val|
				key.match_modified?(self)
			}
		else #ignore a columns modification state and just match
			self.class.internal_cache.delete_if {|key,val|
				key === self
			}
		end
	end

	def primary_key
		return self.class.primary_key;
	end

	#returns the primary key if it is individual or the array or primary keys if there are multiple.
	def get_primary_key()
		if (primary_key.length == 1)
			return self.send(primary_key.first)
		else
			return primary_key.map { |key| self.send(key) }
		end
	end

	#compares the equality of all columns
	def ==(obj)
		return false unless obj.kind_of?(Storable);
		self.class.columns.each_key{|column|
			return false unless (obj.respond_to?(column))
			return false unless (obj.send(column) == self.send(column))
		}
		return true;
	end

	#compares the equality of primary keys
	def ===(obj)
		return false unless (obj.respond_to?(:get_primary_key));
		return self.get_primary_key() == obj.get_primary_key();
	end

	class << self
		public
		
		#Commonly we reference objects by a 3 part unique identifier.
		#This will load an object from such an identifier using the correct storable subclass.
		def load(typeid, primaryid, secondaryid)
			storable_class = TypeID.get_class(typeid);
			if (storable_class.nil?)
				# Note that this is definitely not NEX-2277 but for the life
				# of me, I cannot figure out what bug it really was.
				$log.warning "KNOWN ISSUE NEX-2277: TypeID (#{typeid}) returned nil."
				$log.object caller, :warning
				return nil
			else
				if (storable_class.indexes[:PRIMARY].length > 1)
					return storable_class.find(primaryid, secondaryid, :promise, :first);
				else
					return storable_class.find(primaryid, :promise, :first);
				end
			end
		end

		def test_reset
			self.db.query("TRUNCATE `#{self.table}`")
			self.internal_cache.delete_if {|key, val| true}
			RelationManager.test_reset(self)
		end
		
		#Default prefix is the name of the class.
		def prefix()
			return self.name;
		end

		def _load(str)
			values = Marshal.load(str)

			storable = self.new(false)
			storable.update_method = values[:__update_method__] || :update
			storable.selection = self.get_selection(values[:__selection__]) if values[:__selection__]

			if (storable.selection)
				storable.selection.columns.each_key {|key|
					storable.instance_variable_set(columns[key].sym_ivar_name, values[key])
				}
			else
				self.columns.each_value {|column|
					storable.instance_variable_set(column.sym_ivar_name, values[column.sym_name])
				}
			end

			extra_cache_columns.each_key{|name|
				storable.set_extra_cache_column(name, values[name])
			}

			return storable
		end
		
		def register_event_hook(event, &block)
			self.event_hooks[event] ||= []
			self.event_hooks[event].push(block)
		end
		
		#Wraps the call to new, this allows children classes to override create and return an object of a different
		#class if they have need.
		def storable_new(*args)
			return self.new(*args)
		end

		#returns the column names of the primary key
		def primary_key
			return indexes[:PRIMARY];
		end

		#registers the inherited class in the subclasses hash tree
		def inherited(child)
			@@subclasses[self] ||= []
			@@subclasses[self] << child
			#This is magic that sets up SomeDescendantOfStorable::StorableID::StorableClass to be SomeDescendantOfStorable,
			#and the same for StorableProxy
			child.const_set("StorableID", Class.new(StorableID))
			child::StorableID.const_set("StorableClass", child)
			child.const_set("StorableProxy", Class.new(StorableProxy))
			child::StorableProxy.const_set("StorableClass", child)
			super
		end
		
		def create_id(id, index, selection)
			return self::StorableID.new(id, index, selection)
		end

		#a nested hash of subclasses of the current class
		def subclasses
			return @@subclasses[self];
		end

		#Register either a symbol and list of columns or a custom created StorableSelection object.
		def register_selection(symbol, *cols)
			if (symbol.kind_of?(StorableSelection))
				selection = symbol;
			else
				selection = StorableSelection.new(symbol, *cols);
			end
			self.storable_selections[selection.symbol] = selection;
		end

		#look in current class and parent classes to see if the symbol has been registered anywhere as a selection
		def get_selection(symbol)
			selection = self.storable_selections[symbol];

			if(!selection && self.class.superclass.method_defined?(:get_selection))
				selection = super(symbol)
			end

			return selection;
		end

		#does a selection contain all of the primary key columns for this table?
		def primary_key_selection?(symbol)
			if (symbol.kind_of?(StorableSelection))
				selection = symbol;
			else
				selection = self.get_selection(symbol);
			end
			if (selection.nil?)
				raise SiteError, "Attempted to check primary_key_selection? for non-existant selection: #{symbol}";
			end
			primary_key.each { |key|
				return false unless (selection.valid_column?(key))
			}
			return true;
		end

		# Find is used to retrieve a set of Storable objects. Find takes a
		# list of ids, a list of symbols (options that are set true), and a
		# hash table of options. If the options passed to find do not require
		# special SQL to be included in the query then numerous methods are
		# employed to speed up processing. Complex options will result in each
		# find call performing a query.
		#
		# The options that are available include:
		# * <b>:conditions</b> - An SQL fragment that would follow
		#   <em>WHERE</em>. This can also be an array with a fragment that
		#   includes placeholders and the variables that should be substituted
		#   for them.
		# * <b>:order</b> - A fragment of SQL code that would follow <em>ORDER
		#   BY</em>.
		# * <b>:group</b> - A fragment of SQL code that would follow <em>GROUP
		#   BY</em>.
		# * <b>:having</b> - A fragment of SQL code that would follow
		#   <em>HAVING</em>. It is positioned after :group.
		# * <b>:limit</b> - An integer specifying the maximum number of results
		#   to return.
		# * <b>:offset</b> - An integer specifying offset to the first result.
		#   If you provide offset then remember to provide *:limit* too. It is
		#   recommended to use *:page* instead
		#   to return.
		# * <b>:page</b> - Setup *LIMIT* with offset to provide specific page
		#   of results. You can use *:limit* option to specify page size or
		#   default DEFAULT_PAGE_LENGTH is used
		# * <b>:promise</b> - The query will not be performed until the result
		#   object is used, or until we can include it in another query.
		# * <b>:refresh</b> - The object will be loaded from the database
		#   whether it was cached or not. If the object was cached the cached
		#   version is updated to re-fetch the current state of the database.
		# * <b>:selection</b> - This requires a symbol for a registered
		#   selection object, or a custom built selection object. It will limit
		#   the results to those columns allowed. If a full object has already
		#   been cached it will be returned untouched.
		# * <b>:first</b> - Only the first result is returned and it is not
		#   wrapped in an array. Note that find will cache all provided ids, but
		#   warn if there are any duplicates
		# * <b>:scan</b> - Execute unconstrained query, without limit,
		#   conditions or ids.
		#
		# Some example calls on a theoretical subclass Person:
		# * Person.find(1)
		#   returns an array with one element, primary key id = 1
		# * Person.find(1, 2, 6, :refresh)
		#   returns an array for objects ids (1, 2, 6), refreshes them all from
		#   the database even if they are in memory.
		# * Person.find(*[[7], [17]])
		#   returns an array for objects ids (7, 17)
		#   These are needed to properly query multipart key table.
		# * Person.find([7], [17])
		#   returns an array for objects ids (7, 17)
		# * Person.find(1,2, :promise)
		#   returns an array of promises for the objects ids 1 and 2, these
		#   promises are aggregated when similar promise is executed.
		# * Person.find(:first, :conditions => ["name = ?", "bob"])
		#   returns the first Person whose name is bob
		# * Person.find(:scan) { <process person operations> }
		#   executes streamed find. This will execute provided block on each
		#   returned row (you can use other options too), but will not cache
		#   those results. Use this call to operate on big result sets.
		#   NOTE: during call storable is blocked until it finishes query.
		#         Using old promises inside will not work!
		def find(*args, &block)
			$site.cache.use_context(nil) {
				# force query and omit memcached
				if ($site.config.storable_force_nomemcache)
					args << :nomemcache
				end

				# check if we should make streamable query
				if block_given?
					args << :stream
				end

				# make this a generic recursive deep copy
				original_args = args
				args = args.dclone

				# extract all options
				options = extract_options_from_args!(args);

				# extract all ids
				ids = group_ids(args, options[:index], options[:selection]) if (args.length > 0)

				# check if we can cache ids in internal hash
				cacheable = !ids.nil? && cacheable_options?(options)

				# we're not querying for anything, stop now.
				if (ids.nil? && !options[:limit] && !options[:conditions] && !options[:scan] && !options[:having])
					$log.warning("Unconstrained query without :scan from #{caller[2]}", :sql) if !options[:noscan]
					return StorableResult.new
				end

				# NOTE: If adding new options make sure you don't allow those that need
				#       to be passed to SQL
				if (cacheable)
					# mark all ids as promised. Those will be fetched in all
					# fetch_* family of functions
					promised_ids[options[:selection]] ||= {}
					ids.each{|id| promised_ids[options[:selection]][id] = true}

					if (options[:first])
						if (options[:promise])
							execute_load = lambda {
								result = fetch_ids(options[:selection], ids.first)
								promise_callback(result.first, options[:promise])
							}
							if (options[:force_proxy])
								return self::StorableProxy.new(ids.first.properties_hash, &execute_load)
							else
								return promise(&execute_load)
							end
						else
							result = fetch_ids(options[:selection], ids.first)
							return result.first
						end
					else
						if options[:promise]
							# relation_multi can with an acceptable degree of assuredness pull a list of ids from memcache that
							# it knows will be there and which are always complete keys, it uses :force_proxy to generate objects
							# that can be utilized without ever performing the queries when all that is needed are the ids (very useful)
							#######################################################################################################
							# XXX: there is the danger that nil results show up in the result set here if a requested id isn't found,
							# XXX: or that only the first element of a partial key query will be returned even if there are more
							# XXX: :force_proxy should ONLY be used if the ids passed in are COMPLETE and KNOWN TO EXIST
							if (options[:force_proxy])
								results = ids.map {|id|
									self::StorableProxy.new(id.properties_hash) {
										result = fetch_ids(options[:selection], id).first
										promise_callback(result, options[:promise])
									}
								}
								return StorableResult.new(results)
							else #if we aren't forcing proxy objects then just return a promise to the complete result
								return promise {
									result = fetch_ids(options[:selection], *ids)
									promise_callback(result, options[:promise])
								}
							end
						else
							return fetch_ids(options[:selection], *ids)
						end
					end
				elsif options[:stream]
					# check if options are supported
					if !streamable_options?(options)
						$log.error("Not supported options passed to :stream find from #{caller[2]}", :sql)
						return
					end

					find_streamed(ids, options, &block)
					return
				elsif options[:promise]
					return promise {
						options.delete(:promise);
						args << options;
						result = self.find(*args);
						if (options[:promise].respond_to?(:call))
							options[:promise].call(result)
						else
							result
						end
					}
				end
			
				options.delete(:skip_fetch_ids)
				
				if (args.length > 0)
					if options[:first]
						result = find_by_id(ids.first(1), options)
					else
						result = find_by_id(ids, options)
					end
				else
					# limit result for :first unconstrained query
					# NOTE: this may return multiple rows on striped config
					options[:limit] = 1 if options[:first]
					result = find_all(options);
				end
			
				if (options[:total_rows] && !options[:count])
					new_args = original_args.dclone
					new_args << :count
					result.total_rows = find(*new_args)
				end
			
				return result if options[:count]
				
				if options[:first]
					result = result.first
				elsif cacheable
					result.uniq!
				end

				return result
			}
		end

		def promise_callback(result, promise)
			if (promise.respond_to?(:call))
				promise.call(result)
			else
				result
			end	
		end

		#pulls database query options from the arguments
		def extract_options_from_args!(args) #:nodoc:
			options = {};
			delete_elements = [];
			args.each {|arg|
				if (arg.is_a?(Symbol))
					if (indexes[arg] && !options[:index])
						options[:index] = arg;
					else
						options[arg] = true;
					end
					delete_elements << arg;
				elsif (arg.is_a?(Hash))
					options.merge!(arg);
					delete_elements << arg;
				end
			}
			delete_elements.each {|element|
				args.delete(element);
			}
			if (!options[:index] || !indexes[options[:index]])
				options[:index] = :PRIMARY;
			end
			if (options[:page])
				options[:limit] ||= DEFAULT_PAGE_LENGTH
				options[:offset] ||= (options[:page]-1)*options[:limit]
			end
			return options;
		end

		#retrieve a new secondary id for a given primary id (eg. a message id for a user id).
		def get_seq_id(primary_id)
			self.extend TypeID unless (self.respond_to?(:typeid));
			seq_id = self.db.get_seq_id(primary_id, self.typeid, self.seq_initial_value);
			return seq_id;
		end

		#group any key elements not in an array into key length arrays
		def group_ids(ids, index, selection)
			grouped_ids = []
			temp_id = []
			ids.each {|id|
				if (id.kind_of?(Array))
					grouped_ids << self::StorableID.new(id, index, selection)
				elsif (id.kind_of?(StorableID))
					grouped_ids << id
				else
					temp_id << id
					if (temp_id.length == indexes[index].length)
						grouped_ids << self::StorableID.new(temp_id, index, selection)
						temp_id = []
					end
				end
			}
			if (temp_id.length > 0)
				grouped_ids << self::StorableID.new(temp_id, index)
			end
			return grouped_ids
		end
		
		#interprets an array of ids as a partial specification of an index and creates the SQL condition for it.
		def get_key_conditions(ids, index)
			if (ids.length <= indexes[index].length)
				first = true;
				conditions = indexes[index][0, ids.length].map {|key|
					s = "`#{key}` = " + (split_column?(key) ? '#' : '?');
					s;
				}
				sql = conditions.join(' && ');
				return [sql].concat(ids);
			else
				raise ArgumentError, "Number of ids is greater than the number of primary keys."
			end
		end
		protected :get_key_conditions

		#Returns a hash of selection -> id set.
		#For "select *" queries, the key is nil.  
		def promised_ids
			key = :"#{self}_promised_ids"
			storable_cache = $site.cache.get(:storable_cache, :page) { Hash.new };
			storable_cache[key] ||= {}
			return storable_cache[key]
		end
		
		#setup an extra column to cache in memcache
		#by default uses self.column and self.column= as a getter and setter
		#you can optionally pass in proc/method objects to be used for either/both
		def cache_extra_column(column, getter=nil, setter=nil)
			if (!getter)
				getter = lambda {return self.send(column)}
			end
			if (!setter)
				setter = lambda {|value| return self.send("#{column}=".to_sym), value}
			end
			extra_cache_columns[column] = { :get => getter, :set => setter }
		end
		
		#This function needs to be called once in each subclass after inherited databases, tables, etc have been overwritten.
		#It rechecks column information, sets up attrs, gets primary keys, etc.
		def init_storable(new_db = nil, new_table = nil, new_enums = nil)
			class_attr_accessor(:columns, :fetched_promises, :storable_selections, :indexes, :extra_cache_columns, :event_hooks);
		
			self.storable_selections = Hash.new;
			self.fetched_promises = Hash.new;
			self.indexes = Hash.new;
			self.event_hooks = Hash.new
			set_db(new_db) if (new_db)
			set_table(new_table) if (new_table)
			set_enums(new_enums) if (new_enums) #enum_maps
			self.columns = {};
			self.extra_cache_columns = {};
			db.list_indexes(table).each { |index|
				self.indexes[index['Key_name'].to_sym] ||= []; #initialize to a new array if this is the first column of the key
				self.indexes[index['Key_name'].to_sym] << index['Column_name'];
			}
			primary_key_exists = self.indexes[:PRIMARY]

			db.list_fields(table).each {|column|
				column = Column.new(column, self.enums[column['Field'].to_sym])
				self.columns[column.sym_name] = column

				# initialize attributes for column (value getters/setters)
				if (self.enums.key?(column.sym_name))
					enum_map_attr(column, self.enums[column.sym_name], column.default_ignore_enum)
				elsif (column.sym_type == :enum)
					if(column.boolean?)
						bool_attr(column)
					else
						enum_attr(column, column.enum_symbols)
					end
				else
					attr column.sym_name, true
				end

				# initialize storable column value setter wrapper
				# triggers on_field_change event and stores modifications
				sym_orig_name_eq = :"orig_#{column.name}="
				self.send(:alias_method, sym_orig_name_eq, column.sym_name_eq)
				self.send(:define_method, column.sym_name_eq) {|value|
					modified_hash[column.sym_name] = instance_variable_get(column.sym_ivar_name)
					self.send(sym_orig_name_eq, value)
					self.on_field_change(column.name)
				}

				unless (primary_key_exists)
					self.indexes[:PRIMARY] ||= [] # initialize for first column of the key
					self.indexes[:PRIMARY] << column.name
				end
			}

			# clear this storable cache
			self.internal_cache.clear

			# validate that primary index is not enum map
			# NOTE: enum map is not supported by get_primary_key, === and many
			#       other functions that involve operations on primary indexes
			# NOTE: delete was fixed to support enum_map in primary keys
			self.indexes[:PRIMARY].each {|index|
				if self.columns[index.to_sym].has_enum_map?
					raise "Primary key '#{self.table}.#{index}' should not be enum_map"
				end
			}
		end
		protected :init_storable

		#Sets a class specific db for a subclass, if this isn't called the parents db will be used.
		def set_db(new_db)
			class_attr(:db, true);
			if ($site.dbs.class == Hash && $site.dbs[new_db])
				self.db = $site.dbs[new_db];
			else
				self.db = new_db;
			end
		end
		protected :set_db

		def set_enums(new_enums={})
			class_attr(:enums, true);
			if(!self.enums.nil?() && self.enums.kind_of?(Hash))
				self.enums.merge!(new_enums);
			else
				self.enums = new_enums;
			end
		end
		protected :set_enums

		#Sets a class specific seqtable and area for a subclass, if this isn't called the parents will be used.
		def set_seq_initial_value(new_initial_value)
			class_attr_accessor(:seq_initial_value);
			self.seq_initial_value = new_initial_value;
		end
		protected :set_seq_initial_value

		#Sets a class specific table for a subclass, if this isn't called the parents table will be used.
		def set_table(new_table)
			class_attr(:table, true);
			self.table = new_table;
		end
		protected :set_table

		#returns the storables for the listed ids, if it has to access the database
		#to do so it pulls all promised ids from the database as well.
		def fetch_ids(selection, *ids)
			query_db = false;
			results = StorableResult.new()
			found_ids = []
			ids.each {|id|
				result = cache_load(id);
				if (result != :not_found)
					# unpromise and extract id from cache
					found_ids << id
					promised_ids[selection].delete(id) if promised_ids[selection]
					results = results.concat(result)
				else
					promised_ids[selection] ||= {}
					promised_ids[selection][id] = true
					query_db = true
				end
			}
			ids -= found_ids
			if (query_db)
				fetch_promised_ids()
				ids.each {|id|
					result = cache_load(id)
					results = results.concat(result) if (result != :not_found)
				}
			end
			return results;
		end
		protected :fetch_ids

		#all currently queued promised ids are loaded from the database.  All
		#retrieved storable objects are cached.  Negative hits are cached as nils.
		def fetch_promised_ids()
			#If there are multiple selections queued, get them all
			promised_ids.each {|selection, val|
				ids = val.keys
				#we don't return a result set here, everything we find is cached locally which is where we will look for it
				self.find(:skip_fetch_ids, :selection => selection, *ids) if (ids.length > 0)
			}
			promised_ids.clear()
		end
		protected :fetch_promised_ids

		#get all objects in the ids array that satisfy options
		def find_by_id(id_sets, options)
			cached = []
			cacheable = cacheable_options?(options)

			# extract ids from cache
			if cacheable
				cached = find_in_cache(id_sets, options)
				id_sets = id_sets - cached.meta.keys
			end

			# retrieve all remaining ids from database
			unless (id_sets.empty?)
				options[:conditions] = get_conditions_ids(id_sets, options[:conditions])

				if (options[:count])
					return find_all(options) + cached.length
				else
					result = find_all(options).concat(cached)
					if (cacheable)
						id_sets.each {|id|
							match = result.match(id).uniq
							cache_result(id, match)
						}
					end
					return result
				end
			else
				if (options[:count])
					return cached.length;
				else
					return cached;
				end
			end
		end
		protected :find_by_id

		def get_conditions_ids(ids, conditions)
			# check split requirements
			force_no_split = false
			ids.each {|id|
				unless (id.split?)
					force_no_split = true
					break
				end
			}

			# merge all ids with OR and current conditions with AND
			retcond = ids.collect {|id| id.condition(force_no_split)}
			retcond = self.merge_conditions(" || ", *retcond)
			return self.merge_conditions(" && ", retcond, conditions)
		end
		protected :get_conditions_ids

		def find_in_cache(id_sets, options={})
			cached_vals = StorableResult.new
			cached_vals.meta.keys = []
			id_sets.each { |id_set|
				cached_val = cache_load(id_set);
				if (cached_val != :not_found)
					cached_vals = cached_vals.concat(cached_val)
					cached_vals.meta.keys << id_set
				end
			}
			return cached_vals;
		end
		protected :find_in_cache

		#returns an object from the internal cache based on a set of keys.
		def cache_load(key)
			int_cache = internal_cache
			if int_cache.key?(key)
				return int_cache[key];
			else
				return :not_found;
			end
		end
		protected :cache_load

		def cache_result(id, storable_result)
			unless (storable_result.kind_of? StorableResult)
				if (storable_result)
					storable_result = StorableResult.new([storable_result])
				else
					storable_result = StorableResult.new
				end
			end
			internal_cache[id] = storable_result
			return storable_result
		end
		#protected :cache_result
		
		#caches nil internally for a set of keys, useful for preventing repeated lookups of a missing row
		def cache_nil(id)
			internal_cache[id] = nil
		end
		protected :cache_nil

		#returns an SQL fragment encompassing the 'something' in SELECT something FROM somewhere
		def get_select_string(symbol)
			selection = get_selection(symbol)
			return (selection ? selection.sql : " * " )
		end
		protected :get_select_string

		# construct find SQL query using provided +options+
		def get_query_find(options)
			sql = "SELECT ";

			# type of the query
			if (options[:count])
				sql << " COUNT(*) as `rowcount` "
			else
				sql << " SQL_CALC_FOUND_ROWS " if options[:calc_rows];
				sql << get_select_string(options[:selection]);
			end

			# target table
			sql << " FROM `#{self.table}`"

			# insert all conditions
			if (options[:conditions])
				if options[:conditions].class == String
					sql << " WHERE #{options[:conditions]} ";
				else
					prep_args = options[:conditions].dclone
					sql << " WHERE " + db.prepare(*prep_args);
				end
			end

			# group/order options
			sql << " GROUP BY #{options[:group]} " if options[:group];
			sql << " ORDER BY #{options[:order]} " if options[:order];
			sql << " HAVING #{options[:having]} " if options[:having];

			# limit options
			if (options[:offset] || options[:limit])
				if (!options[:offset])
					sql << " LIMIT #{options[:limit]} "
				elsif (!options[:limit])
					$log.warning("Provided offset, but not limit option", :sql)
					sql << " LIMIT #{options[:offset]},0 "
				else
					sql << " LIMIT #{options[:offset]},#{options[:limit]} "
				end
			end

			return sql
		end
		protected :get_query_find

		#get all objects which satisfy the options
		#this is the lowest level function that all finds go through if they hit the database
		def find_all(options)
			# create SQL query and query server
			sql = get_query_find(options)
			result = self.db.query(sql);
			cached = []

			if (options[:count])
				count = 0
				result.each {|row| count += row['rowcount'].to_i}
				return count
			end

			total_rows = result.total_rows
			
			storables = PagedResult.new;
			storables.page = options[:page]
			storables.page ||= 1
			storables.total_rows = total_rows
			storables.page_length = options[:limit]
			storables.page_length ||= total_rows
			storables.calculated_total = options[:total_rows]
			
			selection = get_selection(options[:selection])

			result.each { |row|
				#Check if the object was already created. This is needed so the previous one can be invalidated if needed.
				keys = indexes[:PRIMARY].map { |key|
					columns[key.to_sym].parse_column(row[key]);
				}

				cached_val = cache_load(self::StorableID.new(keys, :PRIMARY, selection));

				if (cached_val != :not_found)
					if(options[:refresh])
						storable = cached_val.first;
						storable.clear_modified!;
					else
						storables << cached_val.first;
						next;
					end
				else
					storable = self.storable_new(false);
					storable.selection = selection
				end

				storable.total_rows = total_rows;

				if (!selection)
					columns.each_value { |column|
						storable.instance_variable_set(column.sym_ivar_name, column.parse_string(row[column.name]));
					}
				else
					selection.columns.each_key { |name|
						column = columns[name]
						storable.instance_variable_set(column.sym_ivar_name, column.parse_string(row[column.name]));
					}

					if($site.config.environment == :dev)
						storable_class = class << storable; self; end
						columns.each_value {|column|
							if(!selection.valid_column?(column.sym_name))
								storable_class.send(:define_method, column.sym_ivar_name_eq) {|value|
									raise SiteError, "Attempting to set a column (#{column.name}) that was not fetched from the database."
								}
								storable_class.send(:define_method, column.sym_ivar_name) {
									raise SiteError, "Attempting to access a column (#{column.name}) that was not fetched from the database."
								}
							end
						}
					end
				end
				storable.update_method = :update;
				storable.after_load();

				# add storable to results and as caching targets
				cached << storable
				storables << storable
			}

			# NOTE: there may be some unknown reason for this part to be
			# separated. You may try to figure it out, but be warned.
			cached.each {|storable|
				storable.prime_extra_columns
			}
			cached.each {|storable|
				cache_result(storable.storable_id, storable)
			}

			return storables;
		end
		protected :find_all

		# get all objects using streamed query with supplied block. ids will be
		# fetched from cache but results will not be stored inside cache
		def find_streamed(ids, options, &block)

			# merge ids into conditions if not cached, yield all cached
			unless (ids.nil? || ids.empty?)
				# process only first id
				ids = ids.first(1) if options[:first]

				# process all cached values
				cached = find_in_cache(ids, options)
				ids -= cached.meta.keys

				# yield all cached values
				cached.each {|storable|
					yield storable

					# process only single row
					break if options[:first]
				}

				# check if we should still process
				return if ids.empty?

				# merge remaining ids into conditions
				options[:conditions] = get_conditions_ids(ids, options[:conditions])
			end

			# limit result for :first unconstrained query
			# NOTE: this may return multiple rows on striped config
			options[:limit] = 1 if options[:first]

			# create SQL query and query server passing block
			sql = get_query_find(options)
			self.db.query_streamed(sql).each {|row|
				# create storable value
				# NOTE: we preserve self properties
				storable = self.storable_new(false)

				# setup all values (import into ruby values)
				if (options[:selection])
					options[:selection].columns.each_key {|name|
						column = column[name]
						value = column.parse_string(row[column.name])
						storable.instance_variable_set(column.sym_ivar_name, value)
					}
				else
					columns.each_value {|column|
						value = column.parse_string(row[column.name])
						storable.instance_variable_set(column.sym_ivar_name, value)
					}
				end

				# setup storable and call hook
				storable.update_method = :update
				storable.after_load()

				# pass the result to calling block
				yield storable

				# process only single row
				break if options[:first]
			}
		end
		protected :find_streamed

		def internal_cache
			storable_cache = $site.cache.get(:storable_cache, :page) { Hash.new };
			storable_cache[self] ||= {}
			return storable_cache[self]
		end

		def split_column?(column_name)
			splittable = (indexes[:PRIMARY].first.to_sym == column_name.to_sym && self.db.class == SqlDBStripe)
			return splittable
		end
		
		def cacheable_options?(options)
			return (
				!options[:group] &&
				!options[:conditions] &&
				!options[:order] &&
				!options[:refresh] &&
				!options[:page] &&
				!options[:offset] &&
				!options[:count] &&
				!options[:limit] &&
				!options[:stream] &&
				!options[:skip_fetch_ids]
			)
		end
		private :cacheable_options?

		def streamable_options?(options)
			return (
				!options[:promise] &&
				!options[:refresh] &&
				!options[:force_proxy] &&
				!options[:count] &&
				!options[:total_rows] &&
				!options[:calc_rows]
			)
		end

		def merge_conditions(join_with, *conditions)
			key_strings = []
			values = []
			conditions.each {|condition|
				next unless condition
				condition = [*condition]
				key_strings << condition.shift
				values = values.concat(condition)
			}
			if key_strings.length == 1
				[key_strings[0], *values]
			else
				["(#{key_strings.join(join_with)})", *values]
			end
		end
	end

	class ArgumentError < SiteError
	end
end
