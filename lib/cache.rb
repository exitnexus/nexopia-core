
require 'thread';

lib_require :Core, 'memcache';

# x = time given by user
# The value you receive can be x seconds old and will live more x seconds

# When testing use different address such as: 127.0.0.1; localhost; ip; computerName
# Using the same address in different browsers will make it chose the same process

class Cache
	def initialize
		@hash  = Hash.new  # Array[value, timeout]
		@cache = $site.memcache
		@context = nil
	end

	# Set the :context hash to the value passed in and yield the block
	def use_context(context)
		if (context.nil?)
			context = @context || {}
		end
		@context, old_context = context, @context
		begin
			yield
		ensure
			@context = old_context
		end
	end

	# generate memcache key for +key+ and +environment+.
	# By default we use $site.config.environment
	def memcache_key(key, environment = $site.config.environment)
		return "#{environment}-#{self.class}-#{key}"
	end

	# Fetches a value out of the timed cache, or the context cache if registered.
	# If it's :context, only store it in the context hash and if there isn't one
	# just give back what it gets from yield.
	def get(key, time = :context)
		if (time == :page || time == :context)
			# If a context hash has been registered, use that. Otherwise just
			# return what we're yielded.
			if (@context)
				return @context[key] || (@context[key] = yield)
			else
				return yield
			end
		else
			if ( (!@hash.has_key?(key)) || (@hash[key][1] < Time.now.to_i) )
				if ( value = @cache[memcache_key(key)] )
					@hash[key] = Array[value, time + Time.now.to_i]
				else
					@hash[key] = Array[yield, time + Time.now.to_i]
					@cache.set(memcache_key(key), @hash[key][0], time)
				end
			end

			return @hash[key][0]
		end
	end
	
	def delete(key)
		@hash.delete(key)
		@cache.delete(memcache_key(key))
	end
	
end
