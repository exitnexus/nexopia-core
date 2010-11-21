class Array
	def to_option_hash
		options = {}
	
		self.each { | item | 
			if item.is_a? Symbol
				options[item] = true
			elsif item.is_a? Hash
				options.merge! item
			end
		}
	
		return options
	end
end