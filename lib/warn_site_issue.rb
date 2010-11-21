lib_require :Core, 'memcache'
lib_want :Orwell, 'emailer'

class WarnSiteIssue
	WARN_EMAIL = 'bug-reports@nexopia.com'
	
	# Send a warning about a site issue.  This should be used for warnings
	# that REQUIRE developer intervention, but which are not important enough
	# to page the system administrators.  For example, an Orwell task is
	# failing for a given user.  Warnings which are less important should
	# use the KNOWN ISSUE reporter, described at
	# http://svn.office.nexopia.com/trac/development/wiki/Datacenter%20Logs
	# Note that the subject line will be prepended with "SITE ISSUE: ".  Note
	# also that we will send only one email with a given subject line per
	# hour, to avoid overloading QA.
	def self.send_warning(subject, body)
		unless (site_module_loaded? :Orwell)
			raise "Orwell not loaded, unable to send email"
		end
		
		encoded_subject = "WarnSiteIssue-#{URI.encode(subject)}"
		if ($site.memcache.check_and_add(encoded_subject,
			Constants::HOUR_IN_SECONDS))

			# Not sent an email in at least an hour, so it's
			# appropriate to send this warning.
			full_subject = "SITE ISSUE: #{subject}"
			Orwell::send_email(WARN_EMAIL, full_subject, body.to_s)
		end
	end # def self.send_warning
	
end
