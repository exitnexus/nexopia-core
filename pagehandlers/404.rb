lib_want :Debug, "browserinfo"
lib_want :Orwell, "send_email"

require 'cgi'

# This pagehandler defines behaviour for when a page is not found, either
# because there is no handler registered for its path or because it's an attempt
# to go through a 404 handler dispatcher (for lighttpd).
class FourOhFour < PageHandler
	declare_handlers("errors") {
		area :Public
		page :PostRequest, :Full, :report_error, "report_error"

		area :Internal
		page :GetRequest, :Full, :not_found, "404", remain
		page :GetRequest, :Full, :access_denied, "403", remain
		handle :GetRequest, :not_changed, "304", remain
		page :GetRequest, :Full, :error_not_found, remain
	}

	# handles all urls that don't get matched elsewhere.
	def not_found(remain)
		self.status = "404";
		msg = params["message", String];
		
		t = Template.instance("core", "four_oh_four")
		
		puts t.display
	end
	
	def access_denied(remain)
		exception = params.to_hash['exception']
		if (exception.kind_of?(PageRequest::AccessLevelError) && exception.url_to_fix)
			area = remain[0].to_sym
			if (area == :Internal && remain[1] == 'webrequest')
				referer = url("http:/")/remain[2..remain.length] # this probably doesn't belong here...
				param_string = params.to_hash.map { |k,v| v.kind_of?(String) || v.kind_of?(Integer) ? "#{k}=#{CGI.escape(v)}" : nil }.compact * '&'
				referer = referer + '?' + param_string if param_string != ''
			else
				referer = $site.area_to_url([area, exception.request_user])/remain[1..remain.length]
			end
			external_redirect(exception.url_to_fix&{:referer => CGI.escape(referer)}, 302)
		end
		self.status = "403";
		msg = params["message", String, "Unknown Error"];
		puts(%Q{<div class="bgwhite"><h1>403 Forbidden</h1> #{msg}</div>});
	end
	
	def not_changed(remain)
		self.status = "304"
	end


	def error_not_found(remain)
		self.status = remain[0];
		msg = params["message", String, "Unknown Error"];
		token = Time.now.strftime("%H:%M:%S:%Y-%m-%d") + ":" + PageRequest.top.token
		
		puts error_500_page {
			%Q{
				<form method="POST" action="/errors/report_error">		
					<span class="title">What were you trying to do?</span><br/>
					<textarea name="user_message" style="height:55px; width:566px;margin-top: 4px;"></textarea>
					<div class="button">
						<span class="custom_button yui-button yui-button-button">
							<span class="first-child"><button type="submit" minion_name="errors:submit">Send</button></span>
						</span>
					</div>
					<input type="hidden" name="form_key[]" value="#{SecureForm.encrypt(request.session.user, '/Public/errors/report_error')}"/>
					<input type="hidden" name="server_message" value="#{self.status}: #{msg}"/>
					<input type="hidden" name="token" value="#{token}"/>
				</form>
			}
		}
	end
	
	
	def report_error
		user_message = params['user_message', String, '']
		server_message = params['server_message', String, '']
		token = params['token', String, '']

		param_string = ""
		
		if(site_module_loaded?(:Orwell))
			qa_email = $site.config.bug_report_email
			subject = "User Error Report: #{server_message}"
			msg = %Q{h3. Token: [#{token}|#{$site.config.log_viewer_url}?environment=#{$site.config.class.config_name}&language=ruby&token=#{urlencode(token)}]
			
h3. User Message

{quote}
#{escape_jira(user_message)}
{quote}

}

			if(site_module_loaded?(:Debug))
				browserinfo = Debug::BrowserInfo.new(request)
				
				msg = msg + %Q{
h3. Headers
		
}
				
				browserinfo.headers.each { |header|
					header_name = header[0] || "EMPTY"
					header_value = header[1] || "EMPTY"
					msg = msg + %Q{|*#{escape_jira(header_name)}*|#{escape_jira(header_value)}|\n}
				}
				
				msg = msg + %Q{
		
h3. User info

|*User name*|[#{escape_jira(browserinfo.username)}|#{$site.www_url}/users/#{CGI.escape(browserinfo.username)}]|
|*User id*|#{browserinfo.userid}|
|*Skin*|#{escape_jira(browserinfo.userskin)}|
|*Skin type*|#{escape_jira(browserinfo.userskintype)}|
|*State*|#{browserinfo.userstate}|
|*Firstpic*|#{browserinfo.userfirstpic}|
|*Signpic*|#{browserinfo.usersignpic}|


h3. Session info

|*Cookie session key*|#{escape_jira(browserinfo.cookiesessionkey)}|
|*Session info*|#{escape_jira(browserinfo.session)}|
}
				
			end

			Orwell.send_email(qa_email, subject, msg)
		end
		
		puts error_500_page {
			%Q{<span class="confirmation">Thanks!</span>}
		}
	end
	
	
	def error_500_page(&block)
		return %Q{
			<div class="error_page_wrapper" id="error_page_wrapper">
				<img src="#{$site.static_file_url('core/images/500_error.gif')}"/>
				<div class="explanation_container">
					Help us fix this by letting us know what you were trying to do in the box below.  Thanks!<br/><br/>
					-- The Nex Team
				</div>
				<div class="detail_box" id="error_detail_box">
					#{yield}
				</div>
			</div>
		}
	end
	private :error_500_page

	
	def escape_jira(string)
		return string.gsub(/\|/,"\\|")
	end
	private :escape_jira
end
