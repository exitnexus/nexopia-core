lib_require :Core, 'atomic_file', 'bufferio', 'handlertree', 'lrucache', 'typesafehash'
require 'yaml'

class PageError < SiteError
	attr :code;

	def initialize(code)
		super();
		@code = code;
	end
end

class ExceptionPageError < PageError
	attr :original_exception;
	attr :original_backtrace;

	def initialize(exception, backtrace)
		super(500);
		@original_exception = exception;
		@original_backtrace = backtrace;
	end
end

# PageHandler is the core of the pagehandler system. It loads all the relevant
# files from the file system and initializes their classes, collecting information
# about the pages they handle. When a request comes in, it also discovers the
# correct class to call and calls it with the cgi request.
# TODO: Add usage info here.... Someday. Maybe.
class PageHandler
	attr :request;
	attr :status;
	attr :headers;

	attr_reader :params;

	# be careful overloading initialize. If you need to for some reason, make
	# sure you pass along these inputs to super() or everything will break.
	# For routine initialization, use page_initialize instead.
	def initialize(request)
		@request = request;
		@request.handler = self
		@locals = {};

		page_initialize();
	end
	public :initialize

	# base class version does nothing. Overload this for class initialization.
	# child classes should not directly overload initialize without good reason.
	def page_initialize()
	end

	public

	def puts(*args)
		request.reply.out.puts(*args)
	end

	def print(*args)
		request.reply.out.print(*args)
	end

	def printf(*args)
		request.reply.out.puts(*args)
	end

	# Use to get from the PageHandler Local Storage (like Thread LS) from an arbitrary
	# key.
	def [](key)
		return @locals[key];
	end
	# Use to set an item in the PageHandler Local Storage (like Thread LS) an
	# arbitrary item.
	def []=(key, val)
		@locals[key] = val;
	end

	def status=(status)
		reply.headers['Status'] = status.to_s;
	end

	def reply()
		return request.reply;
	end

	def params()
		return request.params;
	end

	def session()
		return request.session;
	end
	
	# Does an internal, user-invisible rewrite to a different handler
	# given the inputs specified.
	# If area is nil (default), uses the currently set domain.
	def rewrite(method, path, params = nil, *area_and_user)
		area_and_user = area_and_user.flatten
		area = area_and_user[0];
		userobj = area_and_user[1];
		@request.dup_modify(
			:method => method,
			:uri => path,
			:params => params,
			:area => area,
			:user => userobj
		) {|newreq|
			PageHandler.execute(newreq);
		}
		throw :page_done; # force us to the end of page execution.
	end
	
	#takes either an http://some.domain.com/path or /path and rewrites it properly, no areas or the like needed
	def simple_rewrite(path)
		if (path.index("http://").nil?)
			path = $site.www_url.to_s + path
		end
		path.sub!("http://", "")
		path = "/webrequest/" + path
		self.rewrite(self.request.method, path, self.params, :Internal)
	end

	# Does an internal, user-invisible, subrequest to a different handler
	# given the inputs specified. Outputs to the out stream object.
	# If area is nil (default), uses the currently set domain.
	def subrequest(out, method, path, params = nil, *area_and_user)
		# to support passing the last argument as an explicit array or individuals
		area_and_user = area_and_user.flatten
		area = area_and_user[0];
		userobj = area_and_user[1];
		newreq = @request.dup_modify(
			:method => method,
			:uri => path,
			:params => params,
			:area => area,
			:reply => PageReply.new(out, false),
			:user => userobj
		) {|req|
			PageHandler.execute(req);
		}
		return newreq;
	end

	# Sends not found headers to the client
	# This call sends raw response without any styling
	def site_not_found(message = nil, status = 404)
		reply.headers['Status'] = status.to_i
		reply.headers['Content-Type'] = MimeType::HTML
		reply.headers['X-info-messages-off'] = true
		puts("#{message}") unless message.nil?
		throw :page_done; # force us to the end of the page execution.
	end

	# Sends redirect headers to the client to another location on the site.
	# If area is nil, goes to the same domain as the current page.
	# status is the status code to send back.  See:
	# http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html
	# By default, we send 301, moved permanently.  Also useful,
	# 302, temporary redirect, and 303, see other.
	def site_redirect(path, area = nil, status = 301)
		base_url = if (area) then $site.area_to_url(area) else request.base_url end;
		external_redirect("#{base_url}#{path}", status);
		throw :page_done; # force us to the end of the page execution.
	end

	# Sends redirect headers to the client to a location on another site.
	# status is the status code to send back.  See:
	# http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html
	# By default, we send 301, moved permanently.  Also useful,
	# 302, temporary redirect, and 303, see other.
	def external_redirect(url, status = 301)
		reply.headers['Status'] = status.to_i;
		reply.headers["Location"] = url;
		puts("<a href=\"#{url}\">Redirecting...</a>");
		throw :page_done; # force us to the end of page execution.
	end

	# If possible, caches the output of the block passed in in a file under
	# the static_file_cache config variable and then serves it. If the file has
	# already been cached, serves that without running the block
	def static_cache(url)
		# TODO: Make this do ETAG/Expire/HEAD stuff to make it more robust.
		reply.headers['Content-Type'] = MimeType.file(url, true).to_s
		if (!$site.config.static_file_cache)
			yield(reply.out)
		else
			file = AtomicFile::create(url) { |out| yield(out) }
#			etag = Digest::MD5.hexdigest(file_path)
			last_modified = file.stat.mtime.gmtime
			# since we're getting mtime off the cached file, this could lead to
			# spurious changed-sinces.

			reply.headers['Expires'] = (Time.now + 365*24*60*60).httpdate
			reply.headers['Last-Modified'] = last_modified.httpdate
#			reply.headers['Etag'] = etag
			#TODO: Make this do the right thing instead of just turning off gzip
#			reply.headers['Content-Encoding'] = "identity"

			reply.body {
				modified_since = request.headers['HTTP_IF_MODIFIED_SINCE']
				modified_since &&= Time.parse(modified_since)
#				client_etag_neg = request.headers['HTTP_IF_NONE_MATCH']
#				client_etag_neg &&= client_etag_neg.sub(/^"(.*)"$/, '\1')
#				client_etag_pos = request.headers['HTTP_IF_MATCH']
#				client_etag_pos &&= client_etag_pos.sub(/^"(.*)"$/, '\1')

#				if ((client_etag_neg && client_etag_neg == etag) ||
#					(client_etag_pos && client_etag_pos != etag) ||
				if(modified_since && last_modified < modified_since) #)
					reply.headers['Status'] = '304 Not Modified'
					reply.out.print("<h2>304 Not Modified</h2>")
				else
#					if (request.headers['SERVER_SOFTWARE'].include?('lighttpd'))
#						reply.headers['X-LIGHTTPD-send-file'] = "#{file.path}"
#					else
						reply.out.puts(file.read)
#					end
				end
			}
		end
		throw :page_done
	end

	def dynamic_cache(key, expire, location = :memcache, &value_block)
		if (location == :site_cache)
			$site.cache.get(key, expire, &value_block)
		elsif ( location == :memcache )
			$site.memcache.get_or_set(key, expire, &value_block)
		else
			$log.warning "Invalid cache location, #{location}"
			yield
		end
	end

	def dynamic_cache_delete(key)
			$site.cache.delete(key)
			$site.memcache.delete(key)
	end


	public

	def run_handler(handler, inputs)
		FileChanges.reload_changed
		if (request.has_access(handler))
			method_name = handler.methods[request.selector];
			$log.spam("Calling handler #{method_name} on #{self.class}", :pagehandler);
			send(method_name, *inputs); # add other arguments.
		else
			#request.html_dump();
			#handler.html_dump();
			puts("Access denied.");
			# todo: throw some kind of error.
		end
	end

	protected

	# This is the singleton part of PageHandler
	PAGEHANDLER_SOURCEDIR = "*/pagehandlers"
	@@handler_classes = {}
	@@handler_tree = HandlerTreeNode.new()
	@@pagehandler_module = {}

	class PageHandlerInfo
		attr_reader :type, :area, :title, :meta, :level, :priv, :klass, :methods, :pass_remain;

		def initialize(type, area, title, meta, level, priv, klass, default_method_name, pass_remain)
			@type = type;
			@area = area;
			@title = title;
			@meta = meta || Hash.new
			@level = level;
			@priv = priv;
			@klass = klass;
			if (default_method_name.kind_of? Hash)
				@methods = default_method_name
			else
				@methods = Hash.new(default_method_name);
			end
			@pass_remain = pass_remain;
		end
		
		def class_name
			return @klass.name
		end

		def add_selector(selector_name, method_name)
			@methods[selector_name] = method_name;
		end

		def method_name()
			return @methods.default;
		end
		
		def dup()
			new_info = PageHandlerInfo.new(@type, @area, @title, @meta, @level, @priv, @klass, @methods, @pass_remain)
			return new_info
		end
	end

	def pagehandler_tree()
		return @@handler_tree;
	end

=begin
	 use this with a block to configure the pagehandler object to handle
	 requests. base_path is a component of the path common to all of the handlers'
	 parts.
	 A declare_handlers section has the following format:
	 declare_handlers("galleries") {
		area :User
		access_level :Any

		# http://users.nexopia.com/username/galleries
		handle :GetRequest, :user_gallery_list
		# http://users.nexopia.com/username/galleries/galleryname
		handle :GetRequest, :user_gallery, input(/.*/)
		# http://users.nexopia.com/username/galleries/galleryname/picid
		handle :GetRequest, :user_gallery_picture, input(/.*/), input(/[0-9]+/)
	}
=end

	def self.inherited(klass)
		@@pagehandler_module[klass] = Thread.current[:current_module]
	end

	def self.pagehandler_module(pagehandler_class)
		return @@pagehandler_module[pagehandler_class]
	end

	def self.declare_handlers(base_path)
		@cur_meta = {
			'keywords' => 'social, network, networking, community, nexopia, nex, canada, canadian, teen, teenager, friend, individual, personality, fun, creep, entertainment, contests',
			'description' => 'Nexopia is the number one online social networking community for teens to connect and express themselves. Interact with friends or meet new ones through personalized profiles, blogs, galleries, games, and one of the biggest user forums on the web.'
		}
		@cur_area = :Public;
		@cur_level = :Any;
		@cur_priv = nil;
		@cur_page = nil;
		@cur_base_path = base_path.split('/');
		if (@base_path)
			new_base_path = []
			@base_path = @base_path.each_with_index {|component, i|
				if (@component == @cur_base_path[i])
					new_base_path << component
				else
					break
				end
			}
			@base_path = new_base_path
		else
			@base_path = @cur_base_path
		end
		@@handler_classes[self.name] = self;
		yield;
	end
	
	#return the base path given to declare handlers, if more than one declare_handlers call has been made it
	#is created by taking the longest prefix match of the base paths
	def self.base_path
		return @base_path
	end

	#instance version of base_path that includes the current area as a prefix to the path
	def current_base_path
		return [self.request.area.to_s] + self.class.base_path
	end

	#returns a form key for the current time, current sessions user, and current pagehandlers default base path
	def form_key
		return SecureForm.encrypt(request.session.user, (url/self.current_base_path).to_s)
	end
	public :form_key
	
	# Record hits for a shared object
	def record_shared_item_hits(object)
		# By default, this method should do nothing.
	end

	# Set the title for all pages handled by this page handler.
	# new_title is the text we use for the title.
	# include_nexopia, if false, excludes the 'Nexopia | ' bit and gives
	# you full control over the title.
	def PageHandler.title(title, include_nexopia = true)
		@cur_title = title
		@cur_title = "Nexopia | " + @cur_title if include_nexopia
	end
	
	# Add the meta information for all pages handled by this page handler.
	# new_meta is the meta information for the page.  This is a hash table
	# of name => value pairs.  For example,
	# meta('description' => 'Nexopia metrics', 'keywords' => 'metrics, sitemetrics')
	# We will merge with the existing meta information.  For example, if
	# we already have 'keywords' => 'foo, bar' and we
	# set_meta('keywords', 'baz'), we end up with
	# 'keywords' => 'foo, bar, baz'.
	# We provide some default keywords and a description, as per NEX-2682.
	def PageHandler.meta(new_meta = {})
		new_meta.each { |name, content|
			if (@cur_meta.has_key?(name))
				if (name == 'keywords')
					@cur_meta[name] = content + ', ' + @cur_meta[name]
				else
					@cur_meta[name] = content + ' ' + @cur_meta[name]
				end
			else
				@cur_meta[name] = content
			end
		}
	end
	
	# the area under which this page handler works. Either :Public, :Self, :User,
	# :Admin, :Internal, or :Upload. These areas will be identified by the url used to
	# get to them. Ie. http://www.nexopia.com/..., http://my.nexopia.com/...,
	# http://users.nexopia.com/username/..., and http://admin.nexopia.com/...
	# respectively. :Internal is not mapped to a domain, but is used for the
	# initial request handling stage.
	def PageHandler.area(area_marker)
		@cur_area = case area_marker
			when :Self
				access_level :IsUser
				area_marker
			when :Public, :Admin, :User, :Internal, :Static, :Images, :UserFiles, :Skeleton
				access_level :Any
				area_marker
			when :Upload
				access_level :LoggedIn
				area_marker
			else
				@cur_area
			end
	end

	# The access level required to view the page. :Any, :NotLoggedIn, :LoggedIn,
	# :Plus, :Admin, :DebugInfo, :IsUser. These are fairly self-explanatory except :IsUser,
	# which will be set if the user viewing the page is also the user being viewed
	# (for the :User area). :DebugInfo is only available to uids in $site.config.debug_info_users.
	def PageHandler.access_level(level_marker, admin_module = nil, admin_priv = nil)
		@cur_level = case level_marker
			when :Any, :NotLoggedIn, :LoggedIn, :Activated, :Plus, :Admin, :DebugInfo, :IsUser, :IsFriend
				level_marker;
			else
				@cur_level;
			end
		if (admin_priv != nil)
			@cur_priv = [admin_module, admin_priv];
		end
	end

	# identifies a member function to handle a particular form of URL under
	# the base_name. Type is the request method (:GetRequest, :PostRequest),
	# method_name is a symbol identifying the member function that handles
	# the request, and path_components is a varargs of the path components
	# that should lead to this handler actually handling the request.
	# path_components will be flattened so arrays can be passed in as if they
	# were splatted. Any argument wrapped in a call to input() will be passed as
	# arguments to the function.
	def PageHandler.handle(type, method_names, *path_components)
		path_components.flatten!
		if (!method_names.kind_of?(Hash))
			method_names = {:Default => method_names};
		end

		pass_remain = false;
		if (path_components.last == :PassRemain)
			pass_remain = true;
			path_components.pop;
		end

		default_method_name = method_names[:Default] || method_names.values.first;

		info = PageHandlerInfo.new(type, @cur_area, @cur_title, @cur_meta, @cur_level, @cur_priv, self, default_method_name, pass_remain);
		method_names.each {|selector, method_name|
			info.add_selector(selector, method_name);
		}

		@cur_page = [@cur_area.to_s] + @cur_base_path + path_components;
		@@handler_tree.add_node(@cur_page, info);
	end

	# form is specified after a page or handle and indicates forms associated with
	# the preceding page or handle.
	def PageHandler.form(selector_name, method_name)
		handler_exists = false;

		# If there's already a post handler for this page, we can skip it.
		page = @cur_page + ["post"];
		@@handler_tree.find_node(page){ |possibility|
			if possibility.type == :PostRequest
				handler_exists = true;
			end
		}
		if !handler_exists
			get_handler = (@@handler_tree.find_node(@cur_page){ |possibility|
				possibility.type == :GetRequest
			})[1];
			post_handler = PageHandlerInfo.new(:PostRequest,
				get_handler.area,
				get_handler.title,
				get_handler.level,
				get_handler.priv,
				get_handler.class_name,
				nil,
				get_handler.pass_remain);
			@@handler_tree.add_node(page, post_handler);
		else
			post_handler = @@handler_tree.find_node(@cur_page){ |possibility|
				possibility.type == :PostRequest
			}.first()
		end


		#page_method = "#{selector_name}_PAGE".to_sym;
		#define_method(page_method, &block);
		post_handler.add_selector(selector_name.to_sym, method_name);


	end

	# page identifies a pagehandler that can also be a full page. It does this
	# by registering two pagehandlers, one of them with the path_components specified
	# that actually goes to a skin full page handler, and one with the element
	# 'body' suffixed. The skin pagehandler is passed the result of the main
	# pagehandler as a string variable.
	# page_type should be either :Full, :Simple, or :Popup. The other arguments
	# are documented on PageHandler.handle.
	def PageHandler.page(type, page_type, method_name, *path_components)
		page_method = "#{method_name}_PAGE".to_sym;
		define_method(page_method) {|*args|
			# Todo: rename skin to skeleton and make this go through Internal.
			rewrite(request.method, (url/:current/:skin/page_type/request.area).to_s + "#{request.uri}:Body", nil, :Skeleton);
		}
		handle(type, {:Default => page_method, :Body => method_name}, *path_components);
	end

	# Declares a rewrite handler. Use as follows:
	#  rewrite(:GetRequest, "x", "y", input(Integer)) {|first| "/y/x/#{first}" }
	# if you return an array, it will pass it in its entirety to the instance rewrite
	# function as the second to nth arguments.
	def PageHandler.rewrite(type, *path_components, &block)
		if (@rewrite_counter.nil?)
			@rewrite_counter = 0;
		else
			@rewrite_counter += 1;
		end
		rewrite_method = "rewrite_#{@rewrite_counter}".to_sym;
		define_method(rewrite_method) {|*args|
			result = block.call(*args);
			if (!result.kind_of? Array)
				result = [result];
			end
			rewrite(request.method, *result);
		}
		
		handle(type, rewrite_method, *path_components);
	end

	# Declares a site redirect handler. See PageHandler.rewrite for more information.
	# Passes through to PageHandler#site_redirect.
	def PageHandler.site_redirect(type, *path_components, &block)
		if (@rewrite_counter.nil?)
			@rewrite_counter = 0;
		else
			@rewrite_counter += 1;
		end
		redirect_method = "redirect_#{@rewrite_counter}".to_sym;
		define_method(redirect_method) {|*args|
			result = block.call(*args);
			if (!result.kind_of? Array)
				result = [result];
			end
			site_redirect(*result);
		}
		handle(type, redirect_method, *path_components);
	end

	# Declares a external redirect handler. See PageHandler.rewrite for more information.
	# Passes through to PageHandler#external_redirect.
	def PageHandler.external_redirect(type, *path_components, &block)
		if (@rewrite_counter.nil?)
			@rewrite_counter = 0;
		else
			@rewrite_counter += 1;
		end
		redirect_method = "redirect_#{@rewrite_counter}".to_sym;
		define_method(redirect_method) {|*args|
			result = block.call(*args);
			if (!result.kind_of? Array)
				result = [result];
			end
			external_redirect(*result);
		}
		handle(type, redirect_method, *path_components);
	end

	# use this to indicate that an argument to handle should be passed into the
	# handler function.
	def PageHandler.input(key)
		return HandlerTreeNode::CaptureInput.new(key);
	end

	# use this as the last argument to a handle or page declaration to indicate
	# that unparsed arguments should be passed in as an array to the last argument.
	def PageHandler.remain()
		return :PassRemain;
	end

	public

	# Gets the currently running pagehandler.
	def PageHandler.current()
		if (Thread.current[:current_pagehandlers])
			return Thread.current[:current_pagehandlers].last;
		else
			return nil;
		end
	end

	# Gets the top level pagehandler for the current request.
	def PageHandler.top()
		if (Thread.current[:current_pagehandlers])
			return Thread.current[:current_pagehandlers].first;
		else
			return nil;
		end
	end

	def PageHandler.modules()
		return PageHandler.top[:modules].uniq.compact
	end

	# Finds a handlertree node that can actually handle the given request.
	# Returns it as four values:
	# - path, the split up version of the string path passed in through the request
	#         object.
	# - remain, the parts of the url passed in that were not used in finding the
	#           request.
	# - handler, the handler object that will actually do the work.
	# - inputs, the variables captured as input into the request.
	def PageHandler.find(request)
		path = request.uri || "/";
		
		valid_key = false
		if (!path.kind_of? Array)
			path = path[1, path.length - 1]; # trim off leading /
			path = path && path.chomp('/'); # trim off trailing /
			path = path && path.split('/').collect {|component| urldecode(component) };
		end
		
		form_keys = request.params['form_key', Array, []]
		valid_key = false
		form_keys.each {|form_key|
			
			# path.clone may seem a little strange, but we just realized that url will clobber path and we need it to not do that.
			if (SecureForm.validate_key(request.session.userid, form_key, (url/request.area.to_s/path.clone).to_s))
				valid_key = true
			end
		}
		
		bad_post_form_key = false
		found = @@handler_tree.find_node([request.area.to_s] + path) { |possibility|
			if (possibility.type == :PostRequest && !valid_key)
				$log.warning "Possible PostRequest '#{possibility.class_name}##{possibility.methods['Default']}' found but form key was invalid."
				bad_post_form_key = true
			end
			(possibility.type == :GetRequest) || (possibility.type == :PostRequest && valid_key) ||
			(possibility.type == :OpenPostRequest && request.method == :PostRequest)
		};
		if(bad_post_form_key)
		  # Check to see if a valid handler was found; if not, we should return 403 instead of 404
  		handlers = found.detect {|f| f.class == PageHandler::PageHandlerInfo}
  		if(handlers.nil?)
  		  # Set the 'inputs' part of the array to 403, since actually raising a PageError here
  		  # does not work properly
  		  found[-1] = "403"
  		end
		end

		return [path] + found
	end

	# Returns an object that contains information about the pagehandler that would
	# be run for the uri specified.
	def PageHandler.query(request)
		path, remain, handler, inputs = PageHandler.find(request);
		
		if (handler)
			handler = handler.dup
			func = handler.methods[request.selector] || handler.methods[:Default]
			func = func.to_s + "_query"
			
			if (handler.klass.respond_to?(func.to_sym))
				return handler.klass.send(func.to_sym, handler)
			end
		end
		return handler
	end

	# Lists the static pagehandler nodes under a particular point in a url given
	# a string url.
	def PageHandler.list_uri(uri, area = nil)
		if (uri.kind_of? String)
			uri = uri.sub(/^\/?(.*)\/?$/, '\1').split('/')
		end
		
		area = area || request.area
		node = @@handler_tree.find_exact([area.to_s] + uri)
		if (node)
			return node.static_nodes.keys
		end
	end
	
	# Returns an object that contains information about the uri specified.
	def PageHandler.query_uri(method, uri, area = nil)
		PageRequest.current.dup_modify(:method => method, :uri => uri.to_s(), :area => area, :selector => ":Body") {|req|
			return PageHandler.query(req)
		}
	end

	# Given a cgi object, finds the pagehandler responsible for the URL given
	# and calls it.
	def PageHandler.execute(request)
		object = nil;
		prev_out = Thread.current[:output];
		if (Thread.current[:current_pagehandlers].nil?)
			Thread.current[:current_pagehandlers] = [];
		end
		begin
			Thread.current[:output] = request.reply.out;

			path, remain, handler, inputs = PageHandler.find(request);
			inputs = inputs.clone

			catch(:page_done) {
				begin
					if (handler.nil?)
						if (path.length > 1 && path[0] == 'errors')
							request.reply.headers['Status'] = '500 Internal Server Error';
							request.reply.out.puts("<h1>500 Internal Server Error</h1>Missing #{path[1]} Error Handler");
							throw :page_done;
						elsif (inputs == "403")
							raise PageError.new(403), "Invalid form key on post request"
					  else
							raise PageError.new(404), "Handler not found for #{request.area}/#{path.join '/'}";
					  end
					else
						# find the object for the class given
						generator = @@handler_classes[handler.class_name];
						object = generator.new(request);

						# Set up the pagehandler stack and push the object onto it
						Thread.current[:current_pagehandlers].push(object);

						PageHandler.top[:modules] ||= [];
						unless (self.pagehandler_module(object.class).nil?)
							PageHandler.top[:modules].push(self.pagehandler_module(object.class));
						else
							$log.object "Unable to load pagehandler_module for #{object.class}.", :error
						end
						begin
							# prepare remaining input arguments
							if (handler.pass_remain)
								inputs.push(remain);
							end

							# execute handler method
							object.run_handler(handler, inputs);

							# update reply title
							if (request.reply.title.empty? &&
								!handler.title.nil? && !handler.title.empty?)
								request.reply.set_title(handler.title, false)
							end

							if (!handler.meta.nil? && !handler.meta.empty?)
								handler.meta.each { |name, content|
									request.reply.set_meta(name, content)
								}
							end
						ensure
							# Pop the pagehandler off
							Thread.current[:current_pagehandlers].pop();
						end
					end
				rescue Errno::EPIPE
					raise; # Just let it go, mostly.
				rescue PageError
					raise; # Handled below as a rewrite.
				rescue Timeout::Error
					raise; # Handled by PageRequest
				rescue Object # handle *anything*
					if (!$!.respond_to?(:page_request))
						def $!.page_request()
							@page_request ||= PageRequest.current
						end
					end
					$log.exception
					raise ExceptionPageError.new($!, $@), "Internal Server Error";
				end
			}
			request.reply.out.end_buffering();
		rescue PageError
			errorhash = {'message' => $!.to_s, 'exception' => $!};
			if ($!.kind_of?(ExceptionPageError))
				errorhash['original_exception'] = $!.original_exception;
				errorhash['original_backtrace'] = $!.original_backtrace;
			end

			if (path.length < 1 || path[0] != 'errors')
				request.dup_modify(
					:uri => "/errors/#{$!.code}/#{request.area}/#{path.join '/'}",
					:area => :Internal,
					:params => errorhash
				) {|request|
					PageHandler.execute(request);
				}
			else
				$log.warning("Double PageError, bailing out.");
			end
		rescue Errno::EPIPE
			$log.warning("Request terminated by EPIPE");
			return request;
		ensure
			if (Thread.current[:current_pagehandlers].nil? || Thread.current[:current_pagehandlers].empty?)
				$site.dbs.each_pair {|name, db|
					db.close();
				}
			end
			Thread.current[:output] = prev_out;
		end
		return request;
	end

	# From this point on loads up the child handlers based on the directory tree PAGEHANDLER_SOURCEDIR
	def PageHandler.find_handlers(path)
		Dir["#{path}/*"].each {|file|
			if (File.ftype(file) == 'directory')
				find_handlers(file) {|inner_file|
					yield(inner_file);
				}
			else
				yield(file);
			end
		}
	end

	def PageHandler.load_pagehandlers()
		$log.info("Searching Modules for pagehandler files.", :pagehandler);

		site_modules() {|mod|
			Thread.current[:current_module] = mod
			modobj = site_module_get(mod)
			meta_info = modobj.meta_module_info
			
			if (!meta_info || meta_info[0] == mod.to_sym)
				$log.info("Loading pagehandlers for module #{mod}", :pagehandler)
				
				find_handlers("#{SiteModuleBase.directory_name(modobj.name)}/pagehandlers") {|file|
					$log.trace("Found #{file}, loading.", :pagehandler);
					require(file);
					FileChanges.register_file(file)
				}
			else
				$log.info("Didn't load pagehandlers for module #{mod} because it's a meta-module", :pagehandler)
			end
		}
	end
end
