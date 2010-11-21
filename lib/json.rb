require 'json'
require 'iconv'

# This gets required by default somehow in the dev environment, but not in trunk/beta/stage/live.
# It re-opens various basic classes to provide proper to_json implementations (among other things,
# I'm sure). One of the things it does is make the Symbol version of to_json equivalent to the 
# String version of to_json, which we need for some of our code to work.
require 'json/add/rails'

class String
	alias :orig_to_json :to_json

	def to_json
		self.utf8.orig_to_json
	end

	
	def utf8
		iconv = (Thread.current['windows-to-utf8'] ||= Iconv.new('UTF-8', 'WINDOWS-1252'))
		
		# I wrote the exception code before discovering the actual 5 characters that caused the problem.
		# Might as well strip those out preemptively (sadly, I must credit George W. Bush - the idiot who
		# managed to tank the global economy in eight short years, among other dubious accomplishments - for
		# making me more likely to use the word "preemptive" to describe something).
		needs_conversion = self.convertible_to_utf8
		
		# And, might as well leave this exception code in, just in case one of our users managed to insert
		# some nasty non-convertible character that we don't know about.
		converted_value = ""
		while(needs_conversion != "")
			begin
				converted_value = converted_value + iconv.iconv(needs_conversion)
				needs_conversion = ""
			rescue Iconv::IllegalSequence => error
				begin
					bad_character = error.failed[0...1]
					$log.warning "KNOWN ISSUE NEX-1154: Bad Character [#{bad_character}]"
					
					converted_value = converted_value + error.success
					# Always skip the first character of the failed sequence so we will eventually end the loop
					needs_conversion = error.failed[1...error.failed.length]
				rescue
					# If anything bad happens here, it's better to just throw the error on up rather than go into an 
					# infinite loop.
					raise error
				end
			end
		end
		
		return converted_value
	end

	# See: http://en.wikipedia.org/wiki/Windows-1252
	#
	# The following represents characters that we will not be able to convert to utf8. The wikipedia article above
	# suggests that these are Windows API control codes.
	#
	# Thus, until we support utf8, and as long as we assume the WINDOWS-1252 character set for our stored data,
	# we should be stripping out the 5 characters that this method strips out when storing any new data (and when
	# converting old data that might have these characters to utf8).
	def convertible_to_utf8
		illegal_character_string = [129,141,143,144,157].map { |i| i.chr }.join
		r = Regexp.new("[#{illegal_character_string}]")
		
		return self.gsub(r,'')
	end
end

# This seems to need to be overridden again to work correctly. See note above (json/add/rails) for more
# explanation as to why we're doing it.
class Symbol
	def to_json
		return self.to_s.to_json
	end
end

class JavascriptFunction
	attr_accessor :function
	def initialize(function)
		self.function = function
	end
	def to_json
		return self.function
	end
end