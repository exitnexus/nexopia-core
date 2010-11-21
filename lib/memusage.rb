require 'inline'
module MemUsage
	class <<self
		begin
			inline do |builder|
				builder.include '<malloc.h>'
				builder.c '
					unsigned long long total()
					{
						return (unsigned long long)mallinfo().arena;
					}
				'
			end
			$log.info("Linux-style mallinfo method worked.", :core)
		rescue # That method failed, try the osx way
			begin
				inline do |builder|
					builder.include '<malloc/malloc.h>'
					builder.c '
						unsigned long long total()
						{
							return (unsigned long long)mstats().bytes_used;
						}
					'
				end
				$log.info("OSX-style mstats method worked.", :core)
			rescue # And fall back to the last resort, we never use any memory.
				def total()
					return 0
				end
				$log.warning("No method of determining memory allocation worked. MemUsage.total will always return 0.", :core)
			end
		end

		def rss
			`ps -o rss= -p #{Process.pid}`.to_i
		end
	end
end
