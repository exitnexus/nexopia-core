lib_require :Core, "data_structures/enum"
#Column acts as a type bridge between SQL and Ruby and also stores column info.
#See core/lib/sql.rb for the bridge between Ruby and SQL.
class Column

	AUTO_INCR = "auto_increment"
	BOOL_Y = 'y'
	BOOL_N = 'n'

	attr_reader :default, :default_value, :primary, :nullable, :extra, :key, :enum_symbols
	attr_reader :name, :sym_name, :sym_name_eq, :sym_name_ex, :sym_ivar_name, :sym_ivar_name_eq, :sym_ivar_name_ex
	attr_reader :sym_type

	#Takes a row from SqlDB#fetch_fields(table) as a constructor.
	def initialize(column_info, enum_map = nil)
		@name = column_info['Field'];
		@sym_name = @name.to_sym
		@sym_name_eq = "#{@name}=".to_sym
		@sym_name_ex = "#{@name}!".to_sym
		@sym_ivar_name = "@#{@name}".to_sym
		@sym_ivar_name_eq = "@#{@name}=".to_sym
		@sym_ivar_name_ex = "@#{@name}!".to_sym

		# setup optional properties
		# NOTE: those are only set if needed, this will make object smaller
		@primary = true if column_info['Key'] == 'PRI'
		@nullable = true if column_info['Null'] != 'NO'
		@extra = column_info['Extra'] if column_info['Extra']

		/^(\w+)(\(.*\))?.*$/ =~ column_info['Type'];
		@sym_type = "#{$1}".to_sym

		@default = column_info['Default'];
		@key = column_info['Key'];

		if (@sym_type == :enum)
			@enum_symbols = Enum.parse_type(column_info['Type'])

			# initialize boolean property for enums
			if (@enum_symbols.length == 2)
				if (enum_symbols.include?(BOOL_N) && enum_symbols.include?(BOOL_Y))
					@boolean = true
				end
			elsif (@enum_symbols.length == 1)
				if (enum_symbols.include?(BOOL_Y))
					@boolean = true
				end
			end
		end
		@enum_map = enum_map unless enum_map.nil?

		# NEX-3565: all column types should map NULL defaults to nil,
		# but we're scared of how badly the site will break if we do
		# them all at once.  Thus we plan to slowly migrate one column
		# type at a time, until they're all done.
		case @sym_type
		when :date
			if (@default.nil?)
				@default_value = nil
			else
				@default_value = parse_string(@default)
			end
		else
			@default_value = parse_string(@default)
		end
	end

	def auto_increment?
		@extra == AUTO_INCR
	end

	def has_enum_map?
		!@enum_map.nil?
	end

	#Transforms a string into the column's corresponding ruby type.
	def parse_string(string)
		if (@enum_map.nil?)
			return self.send(@sym_type, string);
		else
			return enum_map(self.send(@sym_type, string));
		end
	end
	
	def default_ignore_enum
		return self.send(@sym_type, @default);
	end

	#Transforms a string into the column's corresponding pure-ruby type.
	def parse_column(string)
		# check is we have enum
		if (@enum_symbols.nil?)
			# check is we have enum_map
			if (@enum_map.nil?)
				# process generic column
				return self.send(@sym_type, string)
			else
				# process enum column
				if (@boolean)
					return string == BOOL_Y
				else
					return string
				end
			end
		else
			# process generic column (enum_map or not)
			self.send(@sym_type, string)
		end
	end

	#Is the column's ruby type boolean?
	def boolean?()
		@boolean || false
	end

	private
	def varchar(string)
		return string
	end
	def tinyint(string)
		return string.to_i;
	end
	def text(string)
		return string;
	end
	def date(string)
		begin
			return Date.parse(string)
		rescue StandardError
			$log.warning "Error parsing date for column #{@name}, bad value encountered: #{string}"
			return Date.new()
		end
	end
	def smallint(string)
		return string.to_i;
	end
	def mediumint(string)
		return string.to_i;
	end
	def int(string)
		return string.to_i;
	end
	def bigint(string)
		return string.to_i;
	end
	def float(string)
		return string.to_f;
	end
	def double(string)
		return string.to_f;
	end
	def decimal(string)
		return string.to_f;
	end
	def datetime(string)
		method_missing();
	end
	def timestamp(string)
		return string.to_i;
	end
	def time(string)
		method_missing();
	end
	def year(string)
		return string.to_i;
	end
	def char(string)
		return string;
	end
	def tinyblob(string)
		return string;
	end
	def tinytext(string)
		return string;
	end
	def blob(string)
		return string;
	end
	def mediumblob(string)
		return string;
	end
	def mediumtext(string)
		return string;
	end
	def longblob(string)
		return string;
	end
	def longtext(string)
		return string;
	end
	def enum(string)
		if (@boolean)
			return Boolean.new((string == BOOL_Y));
		else
			return Enum.new(string, @enum_symbols);
		end
	end
	def enum_map(string)
		return EnumMap.new(string, @enum_map);
	end
end
