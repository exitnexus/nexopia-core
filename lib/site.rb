class Site
	attr_reader :config_name;
	attr_reader :config;
	attr_reader :dbs;
	attr_reader :cache;
	attr_reader :memcache;
	attr_reader :digest_db;

	def initialize(config_name)
		$site = self
		@config_name = config_name;

		load "core/lib/config.rb";
		@config = ConfigBase.load_config(@config_name);

		require "core/lib/sitemodule";
		lib_require :Core, "var_dump", 'meta', 'chain_method', 'instance_exec', 'url';

		# load idents for static content
		$log.info "Loading static content ident database"

		@digest_db = {
			:files => load_ident_db("digests.static.db"),
			:script => load_ident_db("digests.script.db"),
			:style => load_ident_db("digests.style.db")
		}
	end

	# Load ident database from +file+ and return it as a hash
	# resource => ident elements. Database format: "ident\tresource".
	# When database cannot be loaded then empty hash is returned.
	def load_ident_db(file)
		# ident db automatically merge multiple resources from array
		db = Hash.new { |hash, key|
			if key.kind_of?(Array)
				val = key.map {|k| hash[k]}
				val.join("") if val.compact!.nil?
			end
		}

		begin
			File.open(File.join(Dir.pwd, file)) { |f|
				f.each_line { |line|
					# extract and strip key/value pair
					value, key = line.split("\t")
					key.strip!; value.strip!

					# cache value and extract length
					db[key] = value
				}
			}
		rescue
			unless (self.config.environment == :dev)
				$log.error("Missing or invalid data in ident database: #{file}")
			end
		end

		return db
	end

	def load_skins
		lib_require :Core, "skin_mediator"
		SiteModuleBase.loaded(){|mod|
			if (mod.skeleton?)
				#$site.config.page_skeleton
				SkinMediator.instance.get_skin_list(mod)
			end
		}
	end
	
	def create_dbs()
		# Get configurations for databases and construct the database objects,
		# storing them in the global $dbs.
		lib_require :Core, 'sql/sqlmysql', 'sql/sqlmirror', 'sql/sqlstripe'
		@dbs = ConfigBase.get_dbconfigs(@config_name) {|name, idx, dbconf|
			dbobj = dbconf.create(name, idx);
			dbobj; # return the object back out
		}

		lib_require :Core, "cache";
		@memcache = MemCache.new(*$site.config.memcache_options){|key|
			#This is the same hash function as the php code uses.
			key = key.to_s;
			len = key.size;
			hash = 0;
			(0...len).each{|i|
				hash ^= (i+1)*(key[i]);
			}
			hash;
		}
		@cache = Cache.new();
		lib_require :Core, "php_integration"
	end

	def close_dbs()
		@dbs.each {|dbname, db|
			db.close
		}
	end
	
	def close_memcache()
		@memcache.close
	end

	# Shuts down the entire site and closes database handles.
	def shutdown()
		close_dbs();
		exit();
	end

	def load_modules()
		SiteModuleBase.initialize_modules();
	end

	def load_page_handlers()
		lib_require :Core, "pagehandler", "pagerequest";

		PageHandler.load_pagehandlers();
	end

	def load_templates()
		lib_require :Core, "template/template";
		Template::Cache.load_templates();
		lib_require :Core, "template/css/css_trans";
		CSSTrans::Cache.load_templates();
	end
	
	def default_skeleton
		name = config.page_skeleton
		mod = site_module_get(name)
		if (mod && mod.skeleton?)
			return mod
		else
			# find the first available skeleton and return that
			site_modules {|mod|
				if (mod.skeleton?)
					return mod
				end
			}
		end
		$log.critical("Serious Error: No Skeleton module loaded at all.")
		return nil
	end

	def static_number()
		return @static_number if @static_number
	
		if ($site.config.environment != :dev)
			revstr = '$Revision: 34858 $';
			matches = revstr.match(/Revision: ([0-9]+)/)
			@static_number = matches[1].to_i
		else
			@static_number = Time.now.to_i.to_s
		end
		return @static_number
	end

	def www_url
		return url("http:/")/$site.config.www_url
	end
	def admin_url
		return url("http:/")/$site.config.admin_url
	end
	def admin_self_url
		return url("http:/")/$site.config.admin_self_url
	end
	def upload_url
		return url("http:/")/$site.config.upload_url
	end
	def user_url
		return url("http:/")/$site.config.user_url
	end
	def image_url
		return url("http:/")/$site.config.image_url
	end
	def user_files_url
		return url("http:/")/$site.config.user_files_url
	end
	def self_url
		return url("http:/")/$site.config.self_url
	end
	def static_url
		return url("http:/")/$site.config.static_url
	end
	def style_url
		return static_url/static_number/:style
	end
	def script_url
		return static_url/static_number/:script
	end
	def static_files_url
		return static_url/static_number/:files
	end
	
	# Internal function that provides location string for certain +request+.
	# Search for request resource +res+ is performed in database +db+, format
	# of the result: "static_url/+ident+/+location+/+request+", where +ident+
	# is value (i.e. checksum) that indicate version of the resource.
	def resource_file_url(res, location, request)
		if (ident = @digest_db[location][res]).nil?
			# log only when we are not on dev
			if ($site.config.environment != :dev)
				$log.error("Ident not available for request: #{request} -> #{res}")
			end

			# fallback to old static number ident
			ident = static_number
		end
		return "#{static_url}/#{ident}/#{location}/#{request}"
	end
	
	# Provides location string for static content per resource basis.
	# Returns get part of the query with ident value for +res+ path. Ident is
	# value (i.e. checksum) that indicate version of the resource.
	def script_file_url(request)
		return resource_file_url(request.downcase, :script, request)
	end

	# Gives the url for a CSS file.
	# 'request' is expected to be <skinname>/<modulename>.css
	def css_file_url(request)
		url = "#{$site.config.page_skeleton}/#{request}"
		return resource_file_url(request.downcase.split("/"), :style, url)
	end

	# Provides location string for static content per resource basis.
	# Returns get part of the query with ident value for +res+ path. Ident is
	# value (i.e. checksum) that indicate version of the resource.
	def static_file_url(request)
		# lower first component, module name
		if !(index = request.index('/')).nil?
			res = request[0, index].downcase + request[index, request.length]
		end

		return resource_file_url(res, :files, request)
	end
	
	def colored_img_url(color)
		color = color.gsub(/\#/, '')
		return image_url/:recolour/color/static_number
	end

	def static_file_cache
		return "#{config.static_file_cache}/#{static_number}"
	end
	
	# for use in rubyinfo page. Passes key/value pairs of set config options out via a block
	def get_config_data
		options = [:static_number, :www_url, :admin_url, :admin_self_url, :upload_url, :user_url, :image_url, :user_files_url, :self_url, :static_url, :style_url, :script_url, :static_files_url, :static_file_cache, :default_skeleton]
		options.each {|key|
			if (self.class.instance_method(key).arity == 0)
				yield key.to_s, self.send(key).to_s
			end
		}
	end

	# Translates an area to a domain based on config variables.
	def area_to_url(area)
		user = nil
		if (area.kind_of?(Array))
			area, user = *area
		end
		case area
		when :User
			if (user)
				$site.user_url/user.username
			else
				$site.user_url
			end
		when :Upload then $site.upload_url
		when :Images then $site.image_url
		when :UserFiles then $site.user_files_url
		when :Static then $site.static_url
		when :Admin then $site.admin_url
		when :Self then $site.self_url
		else $site.www_url
		end
	end

	# Translates a domain to an [area, remain] tuple based on config variables.
	# domain can either be a fully qualified domain (http://whatever/blah/blah)
	# or an array of the form ['whatever.com', 'blah', 'blah']
	def url_to_area(domain)
		
		# To match the regex, if we have the root domain we need to append a '/' to
		# the end of the domain string. A length of 1 for domain indicates this.
		append_str = "";
		if (domain.is_a?(Array))
			if(domain.length == 1)
				append_str = "/";
			end
			domain = url("http:/")/domain
			domain += append_str;
		end
		areas = {
			$site.user_url => :User,
			$site.upload_url => :Upload,
			$site.image_url => :Images,
			$site.user_files_url => :UserFiles,
			$site.static_url => :Static,
			$site.admin_url => :Admin,
			$site.self_url => :Self,
			$site.www_url => :Public,
		}

		deepest = [nil, domain]
		areas.each {|url_match, area|
			if ((match = domain.match(/^#{url_match}(\/.*)$/)) &&
				match[1].length < deepest[1].length)
				deepest = [area, match[1]]
			end
		}
		return deepest
	end
	
	def debug_user?(uid)
		config.debug_info_users.include?(uid)
	end
	
	def captcha
		require 'recaptcha'
		@captcha = @captcha || ReCaptcha::Client.new(config.recaptcha_keys[0], config.recaptcha_keys[1])
	end
end
