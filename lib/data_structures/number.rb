class Bignum
	def commify
		# Inserts commas into a number at every thousand
		return self.to_s.gsub(/(\d)(?=(\d\d\d)+(?!\d))/, "\\1,")
	end
end
class Fixnum
	def commify
		# Inserts commas into a number at every thousand
		return self.to_s.gsub(/(\d)(?=(\d\d\d)+(?!\d))/, "\\1,")
	end
end