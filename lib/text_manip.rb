require 'strscan'

class SpamFilterException < Exception
end



class String
	#Wraps text at the specified length, skipping everything inside html tags. 
	# Will break bbcode if run before the bbcode parser.
	def wrap(len, spacer = "&#8203;")
		# Why this funky gsubbing at the start and end? Well, the code below will skip over any html
		# tags so that it doesn't mess up rendering by inserting these damned "shy" characters. Except
		# it doesn't consider the possibility of breaking on any &<name>; type html codes (i.e. &amp;).
		# Instead of trying to add a whole bunch of logic here to deal with that, I'm turning any of
		# those &<name>; codes into an html comment containing the code. Then, at the end, we can 
		# translate those comments back into the codes themselves. This will ensure that we don't break
		# any of them up with a "shy" character.
		self.gsub!(/(&.*?;)/, '<!--\1-->')
		
		s = StringScanner.new(self)
		output = "";
		while(!s.eos?)
			init_pos = s.pos
			word = s.scan(/([^<\s]+)/);
			if (word)
				while (word.length > len)
					output << word[0...len] + spacer;
					word = word[len..-1];
				end
				output << word;
			end
			space = s.scan(/\s+/);
			if (space)
				output << space
			end
			tag = s.scan(/<[^>]*>?/);
			if (tag)
				output << tag;
			end
			if (s.pos == init_pos)
				# Gah!  We didn't advance through our string at all.
				# This means none of the matches above worked.  Let
				# us just dump out the remainder of the string and
				# hope for the best.  May not be wrapped properly,
				# but at least we won't be looping forever.
				output << s.rest();
				s.terminate();
			end
		end
		
		# See comment at the top of this method for why we have to do the funky gsubbing here.
		# BTW, did you know that "shy" stands for "soft hyphen"? I didn't, but it makes so much
		# more sense now...
		return output.gsub(/<!--(&.*?;)-->/, '\1')
	end
	
	def unwrap
		# This is the infamous "shy" character (unicode:00ad) that we insert in the wrap call above. When
		# we're reading any text that we had previously wrapped and that gets passed back in (i.e. via a
		# copy and paste operation), this is what it shows up as in Ruby. Yeah, I know... we really mangle
		# things by inserting this character in the first place. If only our users used more spaces :-( 
		return self.gsub(/\s?(\342\200\213|&#8203;)\s?/,'')
	end

	def spam_filter()
		
		if (!self.match(/canadianiqtest/i).nil?)
			raise SpamFilterException.new("Your comment contained a banned phrase.")
		end
	
		if (self.length <= 1)
			raise SpamFilterException.new("Message is too short.");
		end
		if (self.length > 15000)
			raise SpamFilterException.new("Message is too long.");
		end
	
		#can't break the rest if it's that short
		if (self.length < 200)
			return true;
		end
	
		if (self.count("\n") > 150)
			raise SpamFilterException.new("Message is too many paragraphs.");
		end
		if (self.count(":") > 200)
			raise SpamFilterException.new("Too many smileys.");
		end
		if (self.occurrences_of("[img") > 30)
			raise SpamFilterException.new("Too many images.");
		end
	
		if (self.length > 500)
			wordlen=0;
			html=false;
			total = 0;
			(0...self.length).each{|i|
				if(self[i]== ?< || self[i]== ?[)
					html=true;
				elsif(self[i]== ?> || self[i]== ?])
					html=false;
				end
	
				if !html
					if self[i..i+1].index(/[ \t\n\r\[\]<>]/)
						if(wordlen > 35)
							total += wordlen;
						end
						wordlen=0;
					else
						wordlen +=1;
					end
				end
			}
	
			if (total > 1000)
				raise SpamFilterException.new("Too many overly long words.");
			end
	
			whitespace = self.gsub(/[^\s]+/, '').length;
	
			if whitespace > (self.length / 2)
				raise SpamFilterException.new("Too much white space.");
			end
		end
	
		return true;
	end

	def occurrences_of(substring) 
		count = 0
		i = 0
		loop {
			i = self.index(substring, i)
			break if i.nil?
			count += 1
			i += 1
		}
		return count
	end 

	def titlecase
		non_capitalized = %w{of etc and by the for on is at to but nor or a via}
		gsub(/\b[a-z]+/){ |w| non_capitalized.include?(w) ? w : w.capitalize  }.sub(/^[a-z]/){|l| l.upcase }.sub(/\b[a-z][^\s]*?$/){|l| l.capitalize }
	end
end


def time
	start = Time.now.to_f
	yield
	Time.now.to_f - start;
end

=begin
#str = "kkjasdlkjasldjkkjasdlkjasldjkkjasdlkjasldjkkjasdlkjasldjkkjasdlkjasldjkkjasdlkjasldjkkjasdlkjasldjkkjasdlkjasldjkkjasdlkjasldjkkjasdlkjasldj kkjasdlkjasldjkkjasdlkjasldjkkjasdlkjasldj kkjasdlkjasldjkkjasdlkjasldjkkjasdlkjasldj "
#str = "alskdjaslkdjalskdj  :) kjshdfkjshdkjshdfkjsfdh :transport: kjhsadkhaksjhdas : : : : : : : : : "
#str = File.new("/home/troy/bbcode.txt").read 
str = "Timo wants real words http://kjshdf :( okay :transport: :blush: :blush: :blush: :blush: :blush: :love:"

if (Smilies::smilify(str) != Smilies::smilify4(str))
	puts "comparison failed"
	puts Smilies::smilify(str)
	puts Smilies::smilify4(str)
end

puts time{
	(1..1000).each{
		Smilies::smilify(str);
	}
}
puts time{
	(1..1000).each{
		Smilies::smilify3(str);
	}
}
puts time{
	(1..1000).each{
		Smilies::smilify4(str);
	}
}
puts time{
	(1..1000).each{
		Smilies::smilify5(str);
	}
}
=end
