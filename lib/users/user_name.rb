lib_require :Core, "storable/cacheable"
lib_require :Core, "users/user"

class UserName < Cacheable
	init_storable(:masterdb, 'usernames');
	set_prefix("ruby_username");
	extend(TypeID)

	def to_s
		return self.username
	end

	def uri_info(type = nil)
		return [self.username, nil] if self.live.nil?

		return case type
		when 'userid'
			[self.userid, $site.user_url/self.userid]
		else
			[self.username, $site.user_url/self.username]
		end
	end

	def UserName.by_name(username)
		return find(:first, :conditions => ["username = ? AND live IS NOT NULL", username])
	end

	#returns an array of id, name pairs
	def self.fetch_names_directly(*ids)
		names = []
		if (!ids.empty?)
			result = self.db.query("SELECT * FROM #{self.table} WHERE userid IN ?", ids)

			result.each {|row|
				names << [row['userid'], row['username']]
			}
		end
		
		return names
	end
	
	def before_update()
		$site.memcache.delete("ruby_username-#{@userid}");
	end
	
end

class UserNameReserve < Storable
	init_storable(:masterdb, 'usernames_reserve')

	def UserNameReserve.by_name(username)
		return find(:first, :conditions => ["username = ?", username])
	end

	# ensure that we generated stamp
	register_event_hook(:before_create) do
		self.time = Time.now.to_i unless modified?(:time)
	end
end

class SplitUserName < Storable
	init_storable(:usersdb, 'usernames');
end

