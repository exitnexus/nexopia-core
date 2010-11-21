class MemcachedArray
	def initialize(key, clear_existing_content=false)
		@memcache_key = key
		
		if(clear_existing_content)
			self.clear_memcache!
		end
		
		@array = $site.memcache.get(@memcache_key) || []
		@array_old = @array.dup
	end


	def method_missing(sym, *args, &block)
		val = @array.send sym, *args, &block
		
		if(@array.length != @array_old.length || @array == @array_old)
			$site.memcache.set(@memcache_key, @array, 60*60)
			@array_old = @array.dup
		end
		
		val
	end
	
	
	def clear_memcache!
		$site.memcache.delete(@memcache_key)
		@array = []
		@array_old = @array.dup
	end
end