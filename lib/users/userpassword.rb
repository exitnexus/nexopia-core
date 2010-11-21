require 'digest/md5';

class Password < Storable;
	init_storable(:usersdb, "userpasswords");

	@@salt = "108026098705829461539309790415834498398411555247654961668072468164701"; #random string from random.org

	def Password.check_password(passwd, userid)
		
		stored_password = Password.find(:first, userid)		
		if (!stored_password.nil?)
			hash      = stored_password.password;
			calc_hash = Digest::MD5.new.update( @@salt + passwd).to_s;
		else
			return false
		end
		return (hash == calc_hash);
		
	end
	
	def change_password(passwd)
        if (passwd.length >= 4 || passwd.length <= 32)
			self.password = Digest::MD5.new.update( @@salt + passwd).to_s
	        store
			return true
		else
			return false
		end
	end
end