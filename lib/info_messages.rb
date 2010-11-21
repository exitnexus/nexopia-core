class InfoMessagesOld
	attr_reader :messages
	
	def initialize(messages=[])
		@messages = messages
	end

	def add_message(message)
		@messages << message.to_s
	end
	alias :add_msg :add_message
	alias :addMsg :add_message
	
	def html
		t = Template::instance("info_messages", "info_messages")
		t.messages = self.messages
		return t.display
	end
	
	def display
		result = self.html
		@messages = []
		return result
	end
	
	def clear!
		@messages = []
	end
	alias :clearMsgs :clear!
	
	def empty?
		return @messages.empty?
	end
	
	def text
		return self.messages
	end

	
	def queue_messages(unique_key)
		if (!@messages.empty?)
			$site.memcache.set(self.class.cache_key(unique_key), @messages, 300)
		end
	end
	
	class << self
		def cache_key(unique_key)
			return "#{self}_message_queue-#{unique_key}"
		end

		def fetch_messages(unique_key)
			messages = $site.memcache.get(cache_key(unique_key)) || []
			if (!messages.empty?)
				$site.memcache.delete(cache_key(unique_key))
			end
			return InfoMessagesOld.new(messages)
		end
	
		#executes a block and logs all errors encountered via InfoMessage
		#returns true if an error was logged, false otherwise
		def display_errors(&block)
			begin
				yield
			rescue Object => error
				messages = InfoMessagesOld.new
				messages.add_message(error)
				PageHandler.current.puts messages.html
				return messages
			end
			return false
		end
		
		def capture_errors(&block)
			begin
				yield
			rescue Object => error
				messages = InfoMessagesOld.new
				messages.add_message(error)
				return messages				
			end
			return false
		end
	end # class << self
end # class InfoMessages