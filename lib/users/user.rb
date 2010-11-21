require 'iconv'
lib_require :Core,  'authorization'
lib_require :Core, 	'storable/relation'
lib_require :Core,  'storable/storable'
lib_require :Core,  'accounts'
lib_require :Core,  'constants'
lib_require :Core,  'users/user_name'
lib_require :Core,  'users/interests'
lib_require :Core,  'users/locs'
lib_require :Core,	'users/school'
lib_require :Core,  'users/useremails'
lib_require :Core,  'users/userpassword'
lib_require :Core,  'sql'
lib_require :Core,  'storable/cacheable'
lib_require :Core,	'users/user_ignore'
lib_require :Core,  'user_error'
lib_require :Core,  'skin_mediator'
lib_require :Core, 	'visibility'
lib_require :Core,	'time_format'
lib_require :Core, 'users/deleted_user'
lib_want :UserDump, "dumpable"
lib_want :Worker, :worker

class UserActiveTime < Storable
	init_storable(:usersdb, "useractivetime");
end

class User < Cacheable
	DEFAULT_SKIN = 'newblack'
	
	set_enums(:gallerymenuaccess => Visibility.instance.visibility_list,
		:blogsmenuaccess => Visibility.instance.visibility_list,
		:commentsmenuaccess => Visibility.instance.visibility_list
	);

	init_storable(:usersdb, "users");
	attr_reader :interests, :profile, :password, :galleries, :account;
	attr_accessor :primed_activetime, :email;
	set_prefix("ruby_userinfo")
	
	relation :singular, :useractivetime, :userid, UserActiveTime
	relation :multi, :interests, :userid, UserInterests
	relation :multi, :ignored_user_list, :userid, UserIgnore
	relation :ids, :ignored_by_ids, :userid, UserIgnore, :ignoreid

	relation :singular, :location, :loc, Locs
	relation :singular, :school, :school_id, School
	relation :singular, :username_obj, :userid, UserName
	relation :singular, :password, :userid, Password
	relation :singular, :account, :userid, Account

	cache_extra_column(:username, lambda{ self.username_obj;promise {self.username_obj.nil?() ? nil : self.username_obj.username} }, lambda{|name| @username = name})
	register_selection(:minimal, :userid, :firstpic, :age, :sex, :loc, :activetime, :premiumexpiry)

	#WARNING: DO NOT USE THIS, WE PIGGY BACK THE CACHE KEY FOR THIS IN RelationFriend#
	register_selection(:friend_user, :userid, :firstpic, :age, :sex, :loc)           #
	#WARNING: DO NOT USE THIS, WE PIGGY BACK THE CACHE KEY FOR THIS IN RelationFriend#
	
	include AccountType;
	
	def to_a
		[self]
	end
	
	def id
		return self.userid
	end

	def anonymous?
		return false
	end
	
	def ==(obj)
		return obj.kind_of?(User) && obj.userid == self.userid
	end
	
	#Method string must be in the format Module::Class#method where you can have 0 or more modules
	#hash is passed to the method along with the user object, it must be marshalable
	def self.each(columns, method_string, hash = {})
		self.each_slab_perpetuate_defer(:init, self.db.dbs.keys, columns, method_string, hash)
	end

	def self.each_slab_perpetuate(eachid, dbids, columns, method_string, hash)
		# initialize operation identifier
		if (eachid.nil? || eachid == :init)
			worker = $site.cache.get(:worker) { {} }
			eachid = worker[:task_id]
			eachid = Kernel.rand(2**31) if eachid.nil?
		end

		dbid = dbids.shift
		return if self.db.dbs[dbid].nil?

		# offset userid
		minuserid = 0

		# extract userid ranges for 128 chunks
		# NOTE: get all sorted userids, add row numbers (@no) and extract % rows
		query = "SELECT @no := @no + 1 AS rowno, userid " \
			"FROM (select @no := 0) no, users " \
			"HAVING rowno %128 = 0 ORDER BY userid"
		self.db.dbs[dbid].query(query).each do |row|
			maxuserid = row['userid'].to_i

			# spawn chunk task
			self.each_slab_chunk_defer(
				eachid, dbid, minuserid, maxuserid,
				columns, method_string, hash)

			# update minuserid for next iteration
			minuserid = maxuserid + 1
		end

		# spawn remainder chunk task
		self.each_slab_chunk_defer(
			eachid, dbid, minuserid, nil,
			columns, method_string, hash)

	ensure
		# make sure we perpetuate
		self.each_slab_perpetuate_defer(eachid, dbids, columns, method_string, hash) if dbids.length > 0
	end
	register_task CoreModule, :each_slab_perpetuate, :priority => -120

	def self.each_slab_chunk(eachid, dbid, minuserid, maxuserid, columns, method_string, hash)
		# db to process
		db = self.db.dbs[dbid]

		# chunkid for memcache
		chunkid = "user-each-#{eachid}-#{dbid}-#{minuserid}"

		consts = method_string.split('::')
		class_method = consts.last.split('#')
		method = class_method.last
		consts[-1] = class_method.first

		assembled_const = Object
	 	consts.each {|const| assembled_const = assembled_const.const_get(const)}
		method = assembled_const.method(method)

		# make sure userid column is there
		columns.map! {|column| column.to_sym}
		columns << :userid unless columns.include?(:userid)

		# initialize user object data
		blank_user_hash = {}
		columns.each {|column| blank_user_hash[column] = self.columns[column].default_value}

		# create user object for all chunk processing
		user = self::StorableProxy.new(blank_user_hash) {
			raise Exception.new("Attempted to use non-requested column in User.each")
		}

		# mark object as update
		user.update_method = :update

		# extract all requested data
		if (maxuserid.nil?)
			columns_string = columns.map {|column| "`#{column}`"}.join(', ')
			query = "SELECT #{columns_string} FROM users WHERE userid >= ?"
			rows = db.query(query, minuserid).fetch_set
		else
			columns_string = columns.map {|column| "`#{column}`"}.join(', ')
			query = "SELECT #{columns_string} FROM users WHERE userid BETWEEN ? AND ?"
			rows = db.query(query, minuserid, maxuserid).fetch_set
		end

		# initialize iteration
		$site.memcache.add(chunkid, 0)
		rowid = $site.memcache.incr(chunkid)

		process_row = lambda {|row|
			userid = row['userid'].to_i

			# clean user object
			user.clear_modified!

			# set all requested columns
			columns.each {|name|
				column = self.columns[name]
				value = column.parse_string(row[column.name])
				user.instance_variable_set(column.sym_ivar_name, value)
			}

			# call method to process
			method.call(user, hash)
		}

		# process rows
		if (rowid.nil?)
			rows.each(&process_row)
		else
			while (rowid <= rows.length)
				# process row
				process_row.call rows[rowid - 1]

				# get next row to process, fallback memcache failure
				nextid = $site.memcache.incr(chunkid)
				rowid = nextid.nil? ? rowid + 1 : nextid
			end
		end

		$site.memcache.delete(chunkid)
	end
	register_task CoreModule, :each_slab_chunk, :priority => -119

	# Does a memcache test.
	# Not equivalent to !anonymous.
	#TODO: fix this to take "remember me" into consideration and use constants not magic numbers
	def logged_in?
		curr_time = Time.now.to_i();
		
		if(@primed_activetime.nil?())
			active_time = $site.memcache.get("useractive-#{self.userid}");
		else
			active_time = @primed_activetime;
		end
		
		if(active_time.nil?())
			return false;
		end

		@primed_activetime = active_time;
		active_time = active_time.to_i();
		
		if(active_time > curr_time - $site.config.session_active_timeout)
			return true;
		else
			return false;
		end
	end
	
	def logout!
		time = Time.now.to_i

		self.useractivetime.online = false
		self.useractivetime.store;
		
		self.online = false
		self.timeonline = self.timeonline + (time - self.activetime)
		self.activetime = time

		# we use that for online users stats
		self.db.query("UPDATE usersearch SET active = 1 WHERE userid = #", self.userid);

		# set useractive memcache key
		$site.memcache.set("useractive-#{userid}", time - $site.config.session_active_timeout, 86400*7);
	end
	
	alias original_activetime activetime
	#If you want the most accurate activetime for a user use this call
	def activetime(force_non_zero = false)
		if(!@primed_activetime.nil?())
			t = @primed_activetime.to_i();
			if((!force_non_zero && t == 0) || (force_non_zero && t > 0))
				return t;
			end
		end
		active_time_miss = false;
		
		time = $site.memcache.load("useractive", userid, 86400*7) { |missing_keys|
			active_time_miss = true;
			missing_keys.each_pair{|key, value|
				if (!self.useractivetime.nil?)
					missing_keys[key] = self.useractivetime.activetime.to_i
				else
					missing_keys[key] = self.original_activetime.to_i || 0
				end
			}
		}
		
		if(force_non_zero && time.to_i() == 0 && !active_time_miss && !self.useractivetime.nil?())
			time = self.useractivetime.activetime.to_i();
			$site.memcache.set("useractive-#{self.userid}", time, 86400*7);
		end
		
		@primed_activetime = time.to_i();
		return @primed_activetime;
	end
	
	# This function is used by pages to grab the activetime for groups of
	#  users. This turns getting activetime from n memcache queries to 1.
	def self.prime_user_activetime(user_list)
		user_list.delete_if{|user| user.anonymous?}
		user_id_list = user_list.map{|user| 
			[user.userid]
		};
		
		if(user_list.kind_of?(StorableResult))
			user_hash = user_list.to_hash();
		elsif(user_list.kind_of?(Array))
			user_hash = Hash.new();
			user_list.each{|user| 
				user_hash[[user.get_primary_key()]] = user;
			};
		end	

		active_time_list = $site.memcache.load("useractive", user_id_list, 86400*7) { |missing_keys|
			missing_keys.each_pair{|key, value|
				missing_keys[key] = 0;
			}
		}

		user_hash.each_pair{|user_id, user|
			user.primed_activetime = active_time_list["useractive-#{user_id}"];
		};
	end
	
	def self.get_all_activetime(user_id_list)
		list = $site.memcache.load("useractive", user_id_list, Constants::WEEK_IN_SECONDS) { |missing_keys|
			missing_keys.each_pair{|key, value|
				missing_keys[key] = 0;
			}
		}
		
		return list;
	end
	
	def refresh_activetime
		stamp = Time.now.to_i

		# update user active time
		active_time = UserActiveTime.new
		active_time.userid = self.userid
		active_time.online = true
		active_time.ip = PageRequest.current.get_ip_as_int
		active_time.activetime = stamp
		active_time.hits = 1
		active_time.store(:duplicate, :increment => [:hits, 1])

		# we use that for online users stats
		self.db.query("UPDATE usersearch SET active = 2 WHERE userid = #", self.userid);

		# set useractive memcache key
		$site.memcache.set("useractive-#{self.userid}", stamp, Constants::WEEK_IN_SECONDS)
	end
	
	def has_priv?(mod, bit)
		priv = @priv_obj || @priv_obj = Privilege::Privilege.new(self);
		return priv.has?(mod, bit);
	end
	
	
	def self.get_by_ids(userids)
		return User.find(:all, :conditions => ["userid IN #",userids]);
	end

	def self.get_by_id(userid)
		if(!userid.kind_of?(Integer))
			userid = userid.to_i();
		end
		
		# A negative userid indicates that the user isn't logged in, so just return nil.
		# FIXME: it might be better if we returned the anonymous user, but that requires
		# that we check all the locations where get_by_id is called and make sure it doesn't 
		# break anything. NEX-1652
		if (userid > 0)
			return User.find(:first, :promise, userid);
		else
			return nil
		end
	end

	# Get a user by username.
	# If we set handle_encoding to true, we take care of UTF-8 to
	# WINDOWS-1252 encoding issues, dealing with Ruby to MySQL.
	# Perhaps one day, we'll move our databases to unicode and then
	# we wouldn't need to care about this.
	def self.get_by_name(username, handle_encoding = false)
		user_name = UserName.by_name(username);
		if (handle_encoding && user_name.nil?)
			# Try changing encoding 
			begin
				encoded = Iconv.new('WINDOWS-1252', 'UTF-8').iconv(username)
				user_name = UserName.by_name(encoded)
			rescue
				# Reencoding failed, nothing more we can do
			end
		end

		if (user_name)
			return User.find(:first, user_name.userid);
		else
			return nil;
		end
	end

	def self.get_by_email(email)
		useremail = UserEmail.by_active_email(email)
		return nil if useremail.nil?
		return User.find(:first, useremail.userid)
	end

	def User.create(username, userpassword, useremail, date_of_birth, sex, location, ip, needs_activation = true, needs_terms = true)
		# validate that we can safely add user
		# NOTE: race condition is here
		name = UserName.by_name(username)
		email = UserEmail.by_email(useremail)
		if !(name.nil? || email.nil?)
			raise UserError, "Username already exists" unless name.nil?
			raise UserError, "Email address already used"
		end

		# initialize main objects
		name = nil
		email = nil
		password = nil
		splitname = nil
		user = nil

		# create userid
		userid = create_account()

		# insert username
		begin
			name = UserName.new
			name.userid = userid
			name.username = username
			name.live = true
			name.store
		rescue SqlBase::DuplicationError
			raise UserError, "Username already exists"
		end

		# insert email
		begin
			email = UserEmail.new
			email.userid = userid
			email.active = !needs_activation;
			email.email = useremail
			email.key = "";
			email.time = Time.now.to_i
			email.store
		rescue SqlBase::DuplicationError
			raise UserError, "Email address already used"
		end

		# insert other stuff
		begin
			password = Password.new
			password.userid = userid
			password.change_password(userpassword)
			password.store

			splitname = SplitUserName.new
			splitname.userid = userid
			splitname.username = username
			splitname.store

			user = User.new
			user.userid = userid
			user.date_of_birth = date_of_birth
			user.age = user.calculate_age(user.date_of_birth)
			user.loc = location

			user.sex = sex.to_s
			user.defaultsex = case user.sex
				when 'Male' then 'Female'
				when 'Female' then 'Male'
			end

			user.jointime = Time.now.to_i
			user.activetime = Time.now.to_i
			user.ip = ip

			user.defaultminage = (user.age/2+7).floor
			user.defaultmaxage = (3*user.age/2-5).ceil
			user.state = "active" if !needs_activation
			user.termsversion = 1 if !needs_terms
			user.defaultbrowselist = true
			user.store

			# activate created user
			if (needs_activation)
				user.account.make_new!
			else
				user.account.make_active!
			end

			self.db.squery(user.userid, "UPDATE stats SET userstotal = userstotal + 1")
		rescue SqlBase::QueryError
			$log.exception
			raise UserError, "Unexpected error while creating user"
		end

		return user

	# clean all objects
	rescue Object
		# remove objects that are already inserted
		name.delete unless (name.nil? || name.update_method == :insert)
		email.delete unless (email.nil? || email.update_method == :insert)
		password.delete unless (password.nil? || password.update_method == :insert)
		splitname.delete unless (splitname.nil? || splitname.update_method == :insert)
		user.delete unless (user.nil? || user.update_method == :insert)

		# re-raise exception
		raise
	end
	
	def deleted?
		return self.state == 'deleted'
	end

	def floating_navigation?
		return self.skintype == 'frames'
	end
	
	def floating_navigation=(val)
		self.skintype = val ? 'frames' : 'normal'
	end
	
	def comments_permission
		if (!self.enablecomments)
			return :nobody
		elsif (self.friends_only_comments)
			return :friends
		else
			return :anyone
		end
	end
	
	def comments_permission=(val)
		case val
		when :nobody
			self.friends_only_comments = false
			self.enablecomments = false
		when :friends
			self.enablecomments = true
			self.friends_only_comments = true
		when :anyone
			self.friends_only_comments = false
			self.enablecomments = true
		else
			raise Exception.new("Invalid comment permission.")
		end
	end

	def friends_only_messages
		return self.onlyfriends == 'msgs' || self.onlyfriends == 'both'
	end
	
	def friends_only_messages=(val)
		if (val)
			if (self.onlyfriends == 'neither')
				self.onlyfriends = 'msgs'
			elsif (self.onlyfriends == 'comments')
				self.onlyfriends = 'both'
			end
		else
			if (self.onlyfriends == 'both')
				self.onlyfriends = 'comments'
			elsif (self.onlyfriends == 'msgs')
				self.onlyfriends = 'neither'
			end
		end
	end

	def friends_only_comments
		return self.onlyfriends == 'comments' || self.onlyfriends == 'both'
	end
	
	def friends_only_comments=(val)
		if (val)
			if (self.onlyfriends == 'neither')
				self.onlyfriends = 'comments'
			elsif (self.onlyfriends == 'msgs')
				self.onlyfriends = 'both'
			end
		else
			if (self.onlyfriends == 'both')
				self.onlyfriends = 'msgs'
			elsif (self.onlyfriends == 'comments')
				self.onlyfriends = 'neither'
			end
		end
	end

	def ignore_comments_by_age
		return self.ignorebyage == 'comments' || self.ignorebyage == 'both'
	end
	
	def ignore_comments_by_age=(val)
		if (val)
			if (self.ignorebyage == 'neither')
				self.ignorebyage = 'comments'
			elsif (self.ignorebyage == 'msgs')
				self.ignorebyage = 'both'
			end
		else
			if (self.ignorebyage == 'both')
				self.ignorebyage = 'msgs'
			elsif (self.ignorebyage == 'comments')
				self.ignorebyage = 'neither'
			end
		end
	end



	def ignore_messages_by_age
		return self.ignorebyage == 'msgs' || self.ignorebyage == 'both'
	end
	
	def ignore_messages_by_age=(val)
		if (val)
			if (self.ignorebyage == 'neither')
				self.ignorebyage = 'msgs'
			elsif (self.ignorebyage == 'comments')
				self.ignorebyage = 'both'
			end
		else
			if (self.ignorebyage == 'both')
				self.ignorebyage = 'comments'
			elsif (self.ignorebyage == 'msgs')
				self.ignorebyage = 'neither'
			end
		end
	end


	def activated?
		if (self.state != 'new' && 
			!account.nil? && (account.active? || account.frozen?))

			# Note: We don't check if the useremail record has active set to 'y' because anyone can request
			# a reactivation and we don't want the request itself to affect a user who has already activated
			
			return true;
		else
			return false;
		end
	end

	def after_load()
		# This will ensure that if someone has done a reactivation at some point, but not confirmed, that
		# we'll at least get an email to send a message to, but that we'll attempt to get one marked active
		# before we try to get another.
		@email     = UserEmail.find(:first, :promise, :conditions => ["userid = #", userid], :order => "active = 'y' DESC")
		orig_skin = @skin
		@skin = promise {
			mediator = SkinMediator.instance
			skin_list = mediator.get_skin_list($site.config.page_skeleton)
			if (skin_list.index(orig_skin))
				orig_skin
			else
				DEFAULT_SKIN
			end
		}
		@privileges = promise{ Privilege::Privilege.new(self) }
	end

	def after_create()
		@email     = UserEmail.find(:first, :promise, :conditions => ["userid = # AND active = 'y'", userid])
		if (!SkinMediator.request_skin_list($site.config.page_skeleton).index(@skin))
			@skin = DEFAULT_SKIN
		end
		@privileges = promise{ Privilege::Privilege.new(self) }
		super
	end

	def pronoun
		if (@sex.to_s === "Male")
			"he"
		else
			"she"
		end
	end

	# Note that the delete method almost certainly isn't even remotely
	# close to working.  I tried using it when moving daily prune-unactivated-
	# accounts stuff from Php to Ruby and it failed pretty spectacularly.
	# Fixing this code is probably non-trivial as it requires ensuring all
	# rows in all tables that reference this user are removed properly.
	# Unfortunately, it's also likely that the Php side (auth4.php,
	# function delete()) does not function fully properly.
	def delete()
		update_username = username_obj || UserName.find(:first, self.userid);
		delete_password = password || Password.find(:first, self.userid);
		delete_email = email || UserEmail.find(:first, self.userid);
		delete_splitname = SplitUserName.find(:first, self.userid);
		delete_profile = profile || Profile::Profile.find(:first, self.userid);
		delete_account_maps = AccountMap.find(:all, :conditions => ["accountid = ?", self.userid]);
		
		update_username.live = nil;
		update_username.store;
		
		delete_password.delete() if !delete_password.nil?
		delete_email.delete() if !delete_email.nil?
		delete_splitname.delete() if !delete_splitname.nil?
		delete_profile.delete() if !delete_profile.nil?
		delete_account_maps.each { |map| map.delete() };
		
		super;
	end
	

	def possessive_pronoun
		if (@sex.to_s === "Male")
			"his"
		else
			"her"
		end
	end


	def objective_pronoun
		if (@sex.to_s === "Male")
			"him"
		else
			"her"
		end
	end

	def username()
		if (username_obj.nil?)
			@username ||= "Nexopia-User-Not-Found"
		else
			@username ||= username_obj.username
		end
		return @username
	end

	def username_escaped()
		return CGI::escape(self.username.to_s)
	end

	#triggers an email reactivation
	def set_email(email)
		begin
			new_email = UserEmail.find(:first, self.userid, false)
			new_email = UserEmail.new if new_email.nil?
			new_email.userid = self.userid
			new_email.email = email
			new_email.active = false
			new_email.key = Authorization.instance.makeRandomActivationKey
			new_email.time = Time.now.to_i
			
			new_email.send_activation_email

			new_email.store
			
			# As of Ruby 1.9.x, SMTPError becomes a class, which all of the following SMTP____ exceptions
			# would presumably extend. Right now, they just include it. Because of this, I'm looking for
			# each possible error instead of SMTPError.
		rescue Net::SMTPServerBusy, Net::SMTPSyntaxError, Net::SMTPFatalError, Net::SMTPUnknownError => error
			$log.error "Error sending activation email during reactivation to user with ID: #{user.userid}."
			$log.exception
			raise Exception.new("Unable to send activation email.")
		end
	end

	def email()
		if (@email.nil?)
			return nil;
		end
		
		return @email.email;
	end

	def can_skin?
		free_trial_end = 1269280800 #Monday March 22nd at 12:00 noon Edmonton time (according to timestampgenerator.com)
		return (plus? || Time.now.to_i < free_trial_end)
	end
	
	def plus?
		return Time.now < Time.at(self.premiumexpiry);
	end

	def show_ads?
		return !plus? || !limitads
	end

	def verified?
		return self.signpic;
	end
		
	# Generate an authorization key for an operation associated with this user.
	def gen_auth_key
		return Authorization.instance.make_key(self.userid);
	end
	

	# Returns a list of Account objects identifying what accounts this user is a
	# member of.
	def account_membership()
		mappings = AccountMap.find(:all, :accountid, userid);
		mappings = mappings.collect {|map| map.primaryid; }
		return Account.find(:all, *mappings) if mappings.length > 0
		return []
	end

	def link
		return %Q|<a href="#{uri_info('php')[1]}">#{uri_info('php')[0]}</a>|	
	end
	
	def uri_info(mode = '')
		case mode
		when "", "php"
			return [self.username, $site.user_url/self.username]
		when "comments"
			return [self.username, $site.user_url/self.username/"comments"]
		when "abuse"
			return ["Report Abuse", "/reportabuse.php?type=31&id=#{self.userid}"];
		end
		super(mode);
	end

	def visible?(user_or_id)
		if(user_or_id.kind_of?(User) || user_or_id.kind_of?(AnonymousUser))
			user_target = user_or_id;
		elsif(user_or_id.kind_of?(Integer))
			user_target = User.find(:first, user_or_id);
		else
			raise ArgumentError.new("Wrong type of argument: #{user_or_id.class}");
		end
		
		return _visible?(user_target);
	end
	
	def _visible?(user_target)
		#add ability for admin to always see user
		if(self.frozen? || self.state == "deleted")
			return false;
		end
		
		if((self.hideprofile && self.ignored?(user_target)) || (self.hideprofileanonymous && user_target.anonymous?()))
			return false;
		else
			return true;
		end
	end
	
	def ignore(user_or_id)
		if(user_or_id.kind_of?(AnonymousUser) || user_or_id.kind_of?(DeletedUser))
			return;
		elsif(user_or_id.kind_of?(User))
			user_target = user_or_id;
		elsif(user_or_id.kind_of?(Integer))
			user_target = User.find(:first, user_or_id);
		else
			raise ArgumentError.new("Wrong type of argument: #{user_or_id.class}");
		end
		
		_ignore(user_target)
	end
	
	def _ignore(user)
		# If we're already ignoring the user, don't try to do it twice
		if(self.ignored?(user))
			return
		end
		
		user_ignore = UserIgnore.new
		user_ignore.userid = self.userid
		user_ignore.ignoreid = user.userid
		user_ignore.store(:ignore)
		self.ignored_user_list << user
		
		# Delete the PHP-side key that stores a list of ignored userids
		$site.memcache.delete("ignorelist-#{self.userid}")		
		user.ignored_by_ids << [self.userid, user.userid]
	end
	
	def unignore(user_or_id)
		if(user_or_id.kind_of?(AnonymousUser) || user_or_id.kind_of?(DeletedUser))
			return;
		elsif(user_or_id.kind_of?(User))
			user_target = user_or_id;
		elsif(user_or_id.kind_of?(Integer))
			user_target = User.find(:first, user_or_id);
		else
			raise ArgumentError.new("Wrong type of argument: #{user_or_id.class}");
		end

		_unignore(user_target)
	end
	
	def _unignore(user)
		# If we're already not ignoring the user, don't try to unignore them twice
		if(!self.ignored?(user))
			return
		end
		
		ignore_proxy = UserIgnore::StorableProxy.new(
			{
				:userid=>self.userid,
				:ignoreid=>user.userid
			})
		ignore_proxy.delete

		# Delete the PHP-side key that stores a list of ignored userids
		$site.memcache.delete("ignorelist-#{self.userid}")

		self.ignored_user_list.delete(user)
		user.ignored_by_ids.delete([self.userid, user.userid])
	end
	
	def ignored?(user_or_id)
		if(user_or_id.kind_of?(AnonymousUser) || user_or_id.kind_of?(DeletedUser))
			return false;
		elsif(user_or_id.kind_of?(User))
			user_target = user_or_id;
		elsif(user_or_id.kind_of?(Integer))
			user_target = User.find(:first, user_or_id);
		else
			raise ArgumentError.new("Wrong type of argument: #{user_or_id.class}");
		end
		
		return _ignored?(user_target);
	end
	
	def _ignored?(user_target)
		user_ignore = ignored_user_list.find {|row| row.userid == self.userid && row.ignoreid == user_target.userid }
		
		return !user_ignore.nil?();
	end
	
	def calculate_age(date_of_birth)
		return DateUtils::years_between(date_of_birth)
	end
	
	def remaining_plus_days()
		rem_plus = self.premiumexpiry - Time.now.to_i();
		
		if(rem_plus <= 0)
			return "0";
		end
		
		return sprintf("%.2f", rem_plus/86400.to_f());
	end
	
	def plus_expiry_date()
		return TimeFormat.short_date(self.premiumexpiry);
	end
	
	def frozen?()
		# We should stop checking state == "frozen" pretty much everywhere other than here. Instead,
		# use this method, which will correct state == "frozen" if the user's freeze has expired.
		if (self.state == "frozen" && self.frozentime != 0 && self.frozentime < Time.now.to_i)
			self.state = "active"
			self.store

			# resume subscriptions
			subscriptions_resume
		end
		
		return self.state == "frozen";
	end
	
	def ignore_section_by_age?(section)
		mod_section = section.to_s().downcase();
		
		if(mod_section == "messages")
			mod_section = "msgs";
		end
		
		if(self.ignorebyage == "both" || self.ignorebyage == mod_section)
			return true;
		end
		
		return false;		
	end
	
	def friends_only?(section)
		mod_section = section.to_s().downcase();
		
		if(mod_section == "messages")
			mod_section = "msgs";
		end
		
		if(self.onlyfriends == "both" || self.onlyfriends == mod_section)
			return true;
		end
		
		return false;
	end
	
	
	def database_name
		return $site.dbs[:usersdb].dbs[self.account.serverid].all_options[:db]
	end


	BadUserInfo = Struct.new(:msg, :msg_secondary, :status)
	def bad_user_check
		error_msg = nil
		error_msg_secondary = nil
		error_status = nil
		
		if (!self.activated?)
			error_msg = "You must activate to continue."
			email = UserEmail.find(:first,self.userid).email
			error_msg_secondary = "Click <a href='/account/reactivate?email=#{urlencode(email)}'>here</a> to reactivate"
			error_status = 'unactivated'
		elsif (self.frozen?)
			if (self.frozentime == 0)
				error_msg = "Your account is frozen."
			else
				frozen_days = (self.frozentime - Time.now.to_i) / (60*60*24).to_f
				frozen_days_str = "%.3f" % frozen_days
				error_msg = "Your account is frozen for another #{frozen_days_str} days."
			end
			error_msg_secondary = "<a class=body href='/contactus.php'>Contact an admin if you've got questions.</a>"
			error_status = 'frozen'
		elsif (self.deleted?)
			error_msg = "That account is deleted."
			error_status = 'deleted'
		end
		
		if(error_msg)
			return BadUserInfo.new(error_msg,error_msg_secondary,error_status)
		else
			return nil
		end
	end


	TinyUser = Struct.new(:id, :username)
	class TinyUser
		def json_safe_username()
			begin
				username.to_json
			rescue Iconv::IllegalSequence
				return id.to_s
			end
			return username
		end	
	end

	if (site_module_loaded?(:UserDump))
		extend Dumpable

		def self.user_dump(user_id, start_time = 0, end_time = Time.now)
			user = self.get_by_id(user_id)

			# validate user
			raise UserError, "User does not exist" if user.nil?

			out = "User ##{user_id}\n"
			out += "User name: #{user.username}\n"

			# we need to use storable here as table is split
			UserNameChange.find(user_id,
				:conditions => ["time BETWEEN ? AND ?", start_time, end_time],
				:order => "time DESC") {|entry|

				time = Time.at(entry.time).strftime("%Y/%m/%d %H:%M:%S")
				out += "User name change at #{time}: #{entry.username}\n"
			}

			out += "First name: #{user.firstname}\n"
			out += "Last name: #{user.lastname}\n"
			out += "Account state: #{user.state}\n"
			out += "Joined: #{Time.at(user.jointime).gmtime.to_s}\n"
			out += "Last Active: #{Time.at(user.activetime).gmtime.to_s}\n"
			out += "Frozen: #{Time.at(user.frozentime).gmtime.to_s}\n" if user.frozentime != 0
			daysonline = user.timeonline / Constants::DAY_IN_SECONDS
			hoursonline = user.timeonline / (60 * 60)- (24 * daysonline)
			minsonline = user.timeonline / 60 - (60 * hoursonline + 24 * 60 * daysonline)
			out += "Total time spent online: #{daysonline} days #{hoursonline} hours #{minsonline} minutes\n"
			out += "IP: #{Session.int_to_ip_addr(user.ip)}\n"
			out += "Birthdate: #{user.date_of_birth.strftime('%B %d, %Y')}\n"
			out += "Age: #{user.age}\n"
			out += "Sex: #{user.sex}\n"
			out += "Location: #{user.location}\n"
			out += "School: #{user.school.name unless user.school.nil?}\n"

			return Dumpable.str_to_file("#{user_id}-user.txt", out)
		end
	end
end
