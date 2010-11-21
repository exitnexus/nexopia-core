
# An EnumMap acts as a MySql enum in Ruby, but is backed by a number in MySql.

class EnumMap < Enum
	attr_reader :map
	
	def initialize(value, map)
		@map = map;
		super(get_symbol(value), map.keys);
	end
	
	def get_symbol(value)
		# check symbol
		return value if @map.key?(value)

		# check symbol values
		@map.each_key {|key|
			return key if @map[key] == value || @map[key].to_s == value.to_s
		}

		raise "Invalid symbol (#{value}) for #{@map.keys.inspect}"
	end
	
	def map=(value)
		@map = value
		@symbols = value.keys
	end
	
	def symbol=(value)
		super(get_symbol(value));
	end
	
	def value()
		return @map[@symbol]
	end

	def ordered_keys()
		@map.sort {|a,b| a[1] <=> b[1]}.map {|val| val[0]}
	end

	def [](symbol)
		return @map[symbol];
	end
	
	def to_s()
		return @map[@symbol].to_s;
	end
end
