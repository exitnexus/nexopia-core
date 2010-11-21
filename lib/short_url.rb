class ShortURL
	def self.shorten(longURL)
		path = "/shorten"
		server = "api.bit.ly"
		port = 80
		login = urlencode("nexopia")
		apiKey = urlencode("R_198bde8ca1c0d4f79b6deec8fe8e6088")
		version = "2.0.1"
		format = "json"

		begin
			$log.trace "/shorten?version=#{version}&format=#{format}&login=#{login}&apiKey=#{apiKey}&longUrl=#{longURL}"
		
			# Send an http request to bit.ly to shorten the url we've been given.
			# API documentation is available on the bit.ly website.
			h = Net::HTTPFast.new(server, 80)
			resp, data = h.get("/shorten?version=#{version}&format=#{format}&login=#{login}&apiKey=#{apiKey}&longUrl=#{longURL}")

			case resp.code.to_i
			when 200
				# Success!
			else
				$log.warning("bit.ly returned unexpected http error code when trying to shorten a URL: #{resp.code}")
			end
		rescue Net::HTTPError, SystemCallError
			$log.warning("Failed to shorten url with bit.ly: #{$!}")
		rescue Object
			$log.exception
		end


		# Parsing this object is a little weird. I end up with an array when I thought I would end up with a hash.
		# I've worked around it, but if it breaks take a look at the structure of the object that gets returned before anything else.
		# The object returned from bit.ly is indexed by the long url you pass in which I think is stupid.
		json_obj = JSON.parse(data)

		first_result = nil
		json_obj['results'].each { |result| 
			first_result = result[1]
			break
		}

		return first_result['shortUrl']
	end
	
	#this is based on the guide found here: http://immike.net/blog/2007/04/06/5-regular-expressions-every-web-programmer-should-know/
	URI_REGEX = /(\s|^)((https?:\/\/[\-\w]+(\.\w[\-\w]*)+|([a-z0-9]([-a-z0-9]*[a-z0-9])?\.)+(com|edu|travel|museum|name|jobs|coop|asia|arpa|aero|mobi|pro|tel|biz|gov|in(t|fo)|mil|net|org|[a-z][a-z](\.[a-z][a-z])?))(:\d+)?(\/([^\s\(\)\[\]]*[^\s\.\?!,;<>\[\]\(\)]))?)(\s|.|,|!|$)/i
	def self.parse_and_shorten(string)
		string.gsub(URI_REGEX) { |match|
			link = $2
			pre_extra = $1
			extra = $13
			"#{pre_extra}#{self.shorten(link)}#{extra}"
		}
	end
end
