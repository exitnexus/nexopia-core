###
# This class provides basic manipulation of mime types:
# * maps file name to mime type
# * defines constants to easy access to certain mime types
# * extract media type / sub type of mime type
#
# Example usage:
# puts MimeType::ZIP
# => "application/zip"
# puts MimeType['text/plain']
# => "text/plain"
# puts MimeType['default']      # Note that default mime type MimeType::Default
# => "appliaction/octet-stream" # is used for all unknown mime types
# MimeType.file("Data.csv")
# => "text/plain"
# MimeType.file("Document.pdf")
# => "application/pdf"
# MimeType.file("File.unknown")
# => "appliaction/octet-stream" (or MimeType::Default)
#
###
class MimeType

	# MimeType definition hash
	# key      => mime type text
	# value[0] => constant to contain mime type object if not nil
	# value[1] => matching extensions
	# value[2] => mime type object, this object matches constant (dynamically added)
	#
	# To add new MimeType with only a constant use the following schema:
	# "media_type/sub_type" => [:constant_name, []]
	@@types = {
		"application/pdf"                   => [nil, ["pdf"]],
		"application/pgp-signature"         => [nil, ["sig"]],
		"application/futuresplash"          => [nil, ["spl"]],
		"application/postscript"            => [nil, ["ps"]],
		"application/x-bittorrent"          => [nil, ["torrent"]],
		"application/x-dvi"                 => [nil, ["dvi"]],
		"application/x-gzip"                => [nil, ["gz"]],
		"application/x-ns-proxy-autoconfig" => [nil, ["pac"]],
		"application/x-shockwave-flash"     => [nil, ["swf"]],
		"application/x-tgz"                 => [nil, ["tar.gz", "tgz"]],
		"application/x-tar"                 => [nil, ["tar"]],
		"application/x-bzip"                => [nil, ["bz2"]],
		"application/x-bzip-compressed-tar" => [nil, ["tar.bz2", "tbz"]],
		"application/zip"                   => [:ZIP, ["zip"]],
		"application/xml"                   => [:XML, []],
		"application/xhtml+xml"             => [:XHTML, []],
		"application/xrds+xml"              => [:XRDS, []],
		"appliaction/octet-stream"          => [:Default, ["class", "bin", "exe"]],

		"application/ogg"                   => [nil, ["ogg"]],
		"audio/mpeg"                        => [nil, ["mp3"]],
		"audio/x-mpegurl"                   => [nil, ["m3u"]],
		"audio/x-ms-wma"                    => [nil, ["wma"]],
		"audio/x-ms-wax"                    => [nil, ["wax"]],
		"audio/x-wav"                       => [nil, ["wav"]],

		"image/bmp"                         => [nil, ["bmp"]],
		"image/gif"                         => [nil, ["gif"]],
		"image/jpeg"                        => [:JPEG, ["jpg", "jpeg", "jpe"]],
		"image/png"                         => [:PNG, ["png"]],
		"image/tiff"                        => [nil, ["tif", "tiff"]],
		"image/x-xbitmap"                   => [nil, ["xbm"]],
		"image/x-xpixmap"                   => [nil, ["xpm"]],
		"image/x-xwindowdump"               => [nil, ["xwd"]],

		"video/mpeg"                        => [nil, ["mpeg", "mpg"]],
		"video/quicktime"                   => [nil, ["mov", "qt"]],
		"video/x-msvideo"                   => [nil, ["avi"]],
		"video/x-ms-asf"                    => [nil, ["asf", "asx"]],
		"video/x-ms-wmv"                    => [nil, ["wmv"]],

		"text/css"                          => [:CSS, ["css"]],
		"text/html"                         => [:HTML, ["html", "htm"]],
		"text/javascript"                   => [:JavaScript, ["js"]],
		"text/plain"                        => [:PlainText, ["asc", "c", "h", "hh", "cc", "cpp", "log", "conf", "text", "txt", "csv"]],
		"text/xml"                          => [:XMLText, ["dtd", "xml"]],
	}
	# extensions lookup table
	@@exts = {}

	attr_reader :text
	attr_reader :extensions

	###
	# Constructor
	###

	def initialize(text = "appliaction/octet-stream", extensions = [])
		@text = text
		@extensions = extensions
		@pattern = "^$"

		# setup pattern for name matching
		@pattern = "#{extensions.join("$\|")}$" unless @extensions.empty?
	end

	# Constants generation. This code generates all constants for class and
	# populates @@types with MimeType objects
	@@types.each_pair {|key, value|
		# store MimeType class
		value[2] = MimeType.new(key, value[1])
		value[1].each {|ext| @@exts[ext] = value[2]}
		# create constant if needed
		self.const_set(value[0], key) unless value[0].nil?
	}

	###
	# Class methods
	###

	def self.[] (text)
		return MimeType::Default unless @@types.key?(text)
		return @@types[text][2]
	end

	# Find MimeType for specific file +name+. If corresponding mime type cannot
	# be found then function returns MimeType::Default. If +fast+ lookup is used
	# we first extract file extension (this may be inaccurate) and try to match
	# it with extensions loopup table.
	def self.file(name, fast = false)
		return MimeType::Default unless name
		if fast
			ext = name.sub(/^.*\.([a-zA-Z]+)$/, '\1').downcase
			return @@exts[ext] || MimeType::Default
		else
			@@types.each_value {|value|
				return value[2] if value[2].file(name)
			}
			return MimeType::Default
		end
	end

	# Enumerate all MimeType's
	def self.each
		@@types.each_value {|value|
			yield value[2]
		}
	end

	###
	# Instance methods
	###

	# Extract media type for specific MimeType
	# i.e. image/png => image
	def media_type
		@text[0, @text.index(47)]
	end

	# Extract sub type for specific MimeType
	# i.e. image/png => png
	def sub_type
		@text[@text.index(47) + 1, @text.length]
	end

	# Return +true+ if media type is _application_
	def application?
		return self.media_type == "application"
	end

	# Return +true+ if media type is _image_
	def image?
		return self.media_type == "image"
	end

	# Return +true+ if media type is _audio_
	def audio?
		return self.media_type == "audio"
	end

	# Return +true+ if media type is _video_
	def video?
		return self.media_type == "video"
	end

	# Return +true+ if media type is _text_
	def text?
		return self.media_type == "text"
	end

	# Match specific MimeType with file +name+.
	# Returns +true+ if filename matches or +false+.
	def file(name)
		return false unless name.match(@pattern)
		return true
	end

	# Returns MimeType text
	def to_s
		return @text
	end
end

