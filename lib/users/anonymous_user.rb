lib_want :Preferences, 'sidebar_preferences'

class AnonymousUser
	attr_accessor :userid
	
	def initialize(ip, id=nil)
		if (ip)
			@userid = self.class.ip_to_id(ip)
		else
			@userid = id
		end

		@defaultsex = "Both"
		@defaultminage = 14
		@defaultmaxage = 60
		@defaultonline = false
		@defaultbrowselist = true
		@defaultmightknow = false
		@defaultloc = 0
	end
	
	def username
		return ""
	end

	def has_priv?(*args)
		return false
	end

	def admin?(*args)
		return false
	end
	
	def online
		return false
	end
	
	def id
		return self.userid
	end
	
	def id=(val)
		self.userid=(val)
	end
	
	def anonymous?
		return true
	end
	
	def skintype
		"frames"
	end
	
	def activated?
		return false
	end

	def logged_in?
		return false;
	end
	
	def skin
		return User::DEFAULT_SKIN
	end
	def showrightblocks
		return false;
	end
	def profilefriendslistthumbs
		return true
	end
	
	def can_skin?
		return false
	end
	
	def plus?
		return false
	end

	def show_ads?
		return true
	end
	
	def username_escaped
		return ""
	end

	def ignored?(user)
		return false;
	end

	def age()
		return 0;
	end

	def uri_info
		return ['', '']
	end
	
	def img_info(type = 'landscapethumb')
		return ['', $site.static_file_url("Userpics/images/no_profile_image_#{type}.gif")]
	end
	
	def profilefriendslistthumbs
		return true
	end
	
	
	def pic_mod?()
		return false;
	end
	
	def sidebar_preferences
		return SidebarPreferences.new
	end
	
	def defaultsex
		return @defaultsex
	end
	
	def defaultminage
		return @defaultminage
	end
	
	def defaultmaxage
		return @defaultmaxage
	end
	
	def defaultonline
		return @defaultonline
	end
	
	def defaultbrowselist
		return @defaultbrowselist
	end
	
	def defaultmightknow
		return @defaultmightknow
	end

	def defaultloc
		return @defaultloc
	end
	
	def school_id
		return 0
	end	
	
	def loc
		return 75
	end	
	
	def defaultsex=(value)
		@defaultsex = value
	end
	
	def defaultminage=(value)
		@defaultminage = value
	end
	
	def defaultmaxage=(value)
		@defaultmaxage = value
	end	
	
	def defaultonline=(value)
		@defaultonline = value
	end
	
	def defaultbrowselist=(value)
		@defaultbrowselist = value
	end	

	def defaultmightknow=(value)
		@defaultmightknow = value
	end
	
	def defaultloc=(value)
		@defaultloc = value
	end
	
	def store
		# Do nothing
	end
	
	def experimental_mode
		return false
	end
	
	def ignored_by_ids
		return []
	end
	
	class << self
		def ip_to_id(ip)
			ip = ip.split('.').map {|ip_chunk| ip_chunk.to_i}
			return -(ip[0]*16777216+ip[1]*65536+ip[2]*256+ip[3])
		end
	end
end
