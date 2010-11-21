class DependencyConfig
	attr_accessor :config_module
	
	YUI_VERSION = "2.8.0r4"
	
	YUI_AGGREGATE_FILES = [
		['yahoo', 'dom', 'event', 'connection', 'get', 'datasource', 'autocomplete', 'animation', 'element', 'container', 'menu', 'button', 'json'],
		['dragdrop', 'tabview', 'resize', 'imagecropper', 'uploader'],
		['dragdrop', 'slider', 'colorpicker', 'selector']
	]
	
	# Checksums are generated for agregate javascript files. Remember to
	# perserve format if you modify this:
	# * "MODULE_AGGREGATE_FILES = [" and alone "]" are used as markers
	# * each array is defined in single row
	# * ", " is item delimiter, "[" is list begin, "],?" is list end
	# * all items are quoted with single quotation marks
	MODULE_AGGREGATE_FILES = [
		['core', 'collapsible', 'panels', 'slate', 'shouts', 'enhanced_text_input', 'nexoskel', 'ad_manager', 'rap', 'file_serving'],
		['paginator', 'truncator', 'flash_detect', 'gallery', 'userpics', 'youtube_search', 'json', 'blogs'],
		['autocomplete', 'themed_select', 'profile', 'friends', 'comments']
	]
	
	# Checksums are generated for agregate css files. Remember to
	# perserve format if you modify this:
	# * "CSS_AGGREGATE_FILES = [" and alone "]" are used as markers
	# * each array is defined in single row
	# * ", " is item delimiter, "[" is list begin, "],?" is list end
	# * all items are quoted with single quotation marks
	CSS_AGGREGATE_FILES = [
		['core', 'panels', 'enhanced_text_input', 'nexoskel', 'yui'],
	]
	
	def initialize(script_require=[], static_require=[], yui_require=[], css_require=[])
		@script_require = script_require
		@static_require = static_require
		@yui_require = yui_require		
		@css_require = css_require
	end
	
	def script_require
		@script_require ||= []
		return @script_require
	end
	
	def yui_require
		@yui_require ||= []
		return @yui_require
	end
	
	def static_require
		@static_require ||= []
		return @static_require
	end
	
	def css_require
		@css_require ||= []
		return @css_require
	end
	
	#recursively merge javascript dependencies and then load the paths for the merged list
	def javascript_paths
		unless (@calculated_js_paths)
			js = recursive_config(:script)
			
			script_paths = []
			mod_dup = js.script_require.dup #don't mess up the basic internal structure since we may want to access this multiple times
			
			MODULE_AGGREGATE_FILES.each { |mod_array|				
				extra_mods = mod_array - mod_dup				
				if (extra_mods.length < mod_array.length/2)
					
					mod_dup -= mod_array
					script_paths << $site.script_file_url("#{mod_array.join('-')}.js").to_s
				end
			}
			
			script_paths += mod_dup.map {|mod|
				$site.script_file_url("#{mod}.js").to_s
			}
			
			static_paths = js.static_require.map {|stat|
				$site.static_file_url("#{stat}.js").to_s
			}
			
			yui_dup = js.yui_require.dup #don't mess up the basic internal structure since we may want to access this multiple times
			yui_paths = []
			YUI_AGGREGATE_FILES.each {|yui_array|
				extra_yui = yui_array - yui_dup
				if (extra_yui.length <= yui_array.length/2) #if at least half of the files are needed just load the aggregation
					yui_dup -= yui_array #if we include the aggregate we don't need the yui files it includes anymore
					paths = yui_array.map {|yui|
						"#{YUI_VERSION}/build/#{yui}/#{yui}-min.js"
					}
					yui_paths << "http://yui.yahooapis.com/combo?#{paths.join('&')}"
				end
			}
			yui_paths += yui_dup.map {|yui|
				"http://yui.yahooapis.com/#{YUI_VERSION}/build/#{yui.to_s.chomp('-beta').chomp('-experimental')}/#{yui}-min.js"
			}
			
			config_module_paths = !@config_module.nil? ? [$site.script_file_url("#{@config_module}.js")] : []
 			@calculated_js_paths = (yui_paths + static_paths + script_paths + config_module_paths).map {|path| path.to_s}
		end
		return @calculated_js_paths
	end
	
	def css_paths(skin)
		unless (@calculated_css_paths)
			js = recursive_config(:css)
			
			css_paths = []
			css_module_dup = js.css_require.dup #don't mess up the basic internal structure since we may want to access this multiple times
			
			CSS_AGGREGATE_FILES.each { |css_module_array|				
				# figure out if there are any modules we aren't already going to load
				extra_mods = css_module_array - css_module_dup
				if (extra_mods.length < css_module_array.length/2)
					css_module_dup -= css_module_array
					css_paths << $site.css_file_url("#{skin}/#{css_module_array.join('-')}.css").to_s
				end
				
			}
			css_paths += css_module_dup.map { |mod|
				$site.css_file_url("#{skin}/#{mod}.css").to_s
			}
			
			config_module_paths = !@config_module.nil? ? [$site.css_file_url("#{skin}/#{@config_module}.css")] : []
 			@calculated_css_paths = (css_paths + config_module_paths).map {|path| path.to_s}
		end
		return @calculated_css_paths
		
	end
	
	def recursive_config(purpose = :script)
		js = DependencyConfig.new

		if( purpose == :script )
			requires = self.script_require + self.static_require
		elsif( purpose == :css )
			requires = self.css_require
		else
			raise "Unknown purpose #{purpose} in DependencyConfig#recursive_config. Accepted purposes are [:script, :css]"
		end
		
		requires.uniq.each { |dir_name|
			mod = SiteModuleBase.get(SiteModuleBase.module_name(dir_name))			
			begin
				js += mod.dependency_config.recursive_config(purpose)
			rescue
				$log.error "Unable to load javascript for module: #{dir_name}."
			end
		}
		js += self
		return js
	end

	def +(other_conf)
		
		new_static_require = (self.static_require + other_conf.static_require).compact.uniq
		new_script_require = (self.script_require + [self.config_module] + other_conf.script_require + [other_conf.config_module]).compact.uniq
		new_yui_require = (self.yui_require + other_conf.yui_require).compact.uniq
		new_css_require = (self.css_require + [self.config_module] + other_conf.css_require + [other_conf.config_module]).compact.uniq
		result = self.class.new(new_script_require, new_static_require, new_yui_require, new_css_require)
	end
end
