class String
	#Exactly a string but different class so sql can avoid escaping it
	class NoEscape < String
	end

	def no_escape
		return String::NoEscape.new(self)
	end
end

