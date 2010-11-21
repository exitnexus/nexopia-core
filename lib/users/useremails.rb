lib_require :Core, "storable/cacheable"
lib_want :Orwell, 'send_email'

class UserEmail < Cacheable
	init_storable(:masterdb, "useremails");
	set_prefix("ruby_useremail");

	def UserEmail.by_email(email)
		return find(:first, :conditions => ["email = ?", email])
	end

	def UserEmail.by_active_email(email)
		return find(:first, :conditions => ["email = ? && active = 'y'", email])
	end

	def send_activation_email
		msg = Orwell::SendEmail.new
		msg.subject = "#{$site.config.site_name} Activation Link"
		msg.send(User.get_by_id(self.userid), 'activation_email_plain', 
			:html_template => 'activation_email_html', 
			:template_module => 'account', 
			:key => self.key,
			:to => self.email,
			:referer => '/my/preferences/account'
		)
	end
end
