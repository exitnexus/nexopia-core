lib_require :Core, "storable/cacheable"
lib_require :Core, "users/user", "abuse_log"
lib_want :Gallery, 'gallery_pic'
lib_want :Scoop, "simple_reporter"
lib_want :Userpics, 'pics'

# Table with username changes
class UserNameChange < Cacheable
	init_storable(:usersdb, 'usernames_change')

	include Scoop::SimpleReporterInterface
	extend TypeID

	relation :singular, :user, [:userid], User
	report :create, {:sort => :scoop_sort, :precheck => :create_scoop_event?, :report_readers => :readers}

	def uri_info(type = nil)
		return case type
		when 'userid'
			[self.userid, $site.user_url/self.userid]
		else
			[self.username, $site.user_url/self.username]
		end
	end

	def UserNameChange.by_name(username)
		return find(:conditions => ["username = ?", username])
	end

	# *** FriendsFeed methods ***
	def friends_feed_content
		t = Template.instance("friends_feed", "friends_feed_username_change")
		t.owner = self.user
		t.source = self
		return t.display
	end

	def owner
		self.user
	end
	
	def source
		self
	end
	# END FriendsFeed methods END

	# *** Scoop methods ***
	def createtime
		self.time
	end

	def createtime= (value)
	end

	def create_scoop_event?
		true
	end
	# END Scoop methods END
end

class User < Cacheable
	# Return cost of username change for user
	def change_username_cost
		1000
	end

	# Change username of the user to +name+. We assume that this change is at
	# user request for logging purposes
	def change_username (name, modid = nil)

		# get username object
		username = UserName.find(userid, :first)
		current_name = username.username

		# check if name is available
		begin
			username.username = name
			username.store
		rescue SqlBase::DuplicationError
			raise UserError, "That username already exists"
		end

		# update signpic property
		self.signpic = false
		self.store

		# Get rid of any existing sign pic.
		pics.each { |pic|
			if pic.signpic?
				pic.gallery_pic.signpic = :unmoderated
				pic.gallery_pic.store
				pic.signpic = false
				pic.store
				break
			end
		}

		# store old username in changelog
		# this automatically generates event
		changelog = UserNameChange.new
		changelog.userid = userid
		changelog.username = current_name
		changelog.time = Time.now.to_i
		changelog.store()

		# store username change event in AbuseLog
		if (modid.nil?)
			AbuseLog.make_entry(0, userid,
				AbuseLog::ABUSE_ACTION_CHANGE_USERNAME,
				AbuseLog::ABUSE_REASON_REQUEST,
				"Username change: #{current_name} => #{name}",
				"Username change at user request from #{current_name} to #{name}")
		else
			AbuseLog.make_entry(modid, userid,
				AbuseLog::ABUSE_ACTION_CHANGE_USERNAME,
				AbuseLog::ABUSE_REASON_REQUEST,
				"Username change: #{current_name} => #{name}",
				"Username change at mod request from #{current_name} to #{name}")
		end

		# send user a confirmation message
		message = Message.new
		message.sender_name = "Nexopia"
		message.receiver = self
		message.subject = "Username changed!"
		message.text = "You have succesfully changed your username to #{name}, have fun!\n\n-- The Nex Team"
		message.send
	end
end


