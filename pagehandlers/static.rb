lib_want :Profile, "user_skin";
lib_require :Core, 'json'

class StaticHandler < PageHandler
	declare_handlers("/") {
		area :Static
		handle :GetRequest, :static, input(String), :files, input(String), remain # ruby module static files
		handle :GetRequest, :combo_script_js, input(String), :script, input(/^(.+)\.js$/); # revision/script/module.js
		# handle :GetRequest, :old_css, input(Integer), :style, input(String), input(/^(.+)(\d)\.css$/) #revision/style/skeletonname/skinname.css
		handle :GetRequest, :css, input(String), :style, input(String), input(String), input(/^(.+)\.css$/) #revision/style/skeletonname/skinname/modulename.css
	}

	# Internal function to return ident value for resource +res+ from database
	# +db+. If non nil value is returned then +ident+ value does not match entry
	# in the database and user should be redirected to updated resource.
	# NOTE: When +ident+ starts with "r" character then it indicate db lookup,
	#       however special case, alone "r" indicate no db lookup and *NO*
	#       redirect. Note that we fall-back to static number (revision) when no
	#       entry in +db+ or +ident+ does not start with "r" character.
	def check_ident(res, db, ident)
		if (ident[0] == ?r)
			return nil if (ident.length == 1)

			value = db[res]
			if (value.nil?)
				$log.error "Ident (#{ident}) not available for request: #{res} (#{res.class})"
				return $site.static_number.to_s
			elsif (ident != value)
				return value
			end
		elsif (ident != $site.static_number.to_s)
			return $site.static_number.to_s
		end
		return nil
	end

	def static(ident, modname, remain)
		# Don't try to write info message info out with a static file
		request.reply.headers["X-info-messages-off"] = true
		
		# redirect to update user cache
		if $site.config.environment != :dev
			res = "#{modname.downcase}/#{remain.join('/')}"
			ident = check_ident(res, $site.digest_db[:files], ident)
			site_redirect(url/ident/:files/modname/remain, :Static, 303) unless ident.nil?
		end

		# extract module (we use downcase lookup)
		mod = SiteModuleBase.get(modname.downcase, true)
		if mod.nil?
			request = "#{ident}/files/#{modname}"
			request += "/#{remain.join('/')}" unless remain.empty?
			$log.error("SiteModuleBase (#{modname}) not found: #{request}")
			return
		end

		# sent contents of static file
		if static_path = mod.static_path()
			file_path = "#{static_path}/#{remain.join('/')}"

			static_cache("/files/#{mod.to_s}/#{remain.join('/')}") {|out|
				if (File.file?(file_path))
					out.puts(File.read(file_path))
				else
					site_not_found("Static file not found")
				end
			}
		end
	end

	# handles loading CSS files, either fetching from cache or generating them on the fly if they
	# haven't been created yet.
	def css(ident, skeleton, skin_name, module_match)
		
		# Don't try to write info message info out with a CSS file
		request.reply.headers["X-info-messages-off"] = true		
		
		#if( $site.config.environment != :dev )
			ident = check_ident([skin_name, module_match[0]], $site.digest_db[:style], ident)			
			site_redirect(url/ident/:style/skeleton/skin_name/module_match[0], :Static, 303) unless ident.nil?
		#end
		
		
		reply.headers["Content-Type"] = MimeType::CSS
		# skeleton_module_name_decapsed = SiteModuleBase.module_name(skeleton);
		skeleton_module = SiteModuleBase.get(skeleton) || SiteModuleBase.get(SiteModuleBase.module_name(skeleton))		
		if (skeleton_module && skeleton_module.skeleton?)

			module_names = module_match[1].split('-')			
			static_cache("/style/#{SiteModuleBase.directory_name(skeleton_module.name)}/#{skin_name}/#{module_match[0]}") { |out|
				module_names.each { |module_name| 
					output_module_css(skeleton, skeleton_module, skin_name, module_name, out)
				}
			}
			
		end
		
	end

	# Serve the css file for a given skeleton/skin/module combination.
	def output_module_css(skeleton, skeleton_module, skin_name, module_name, out)
				
		sio = StringIO.new
		# Get css for skeleton
		if( skeleton.downcase == module_name.downcase )
			
			# get css from both the control and layout directories in the skeleton directory.
			skel_layout = skeleton_module && skeleton_module.layout_path()
			out.puts(load_css(skel_layout, skeleton, skin_name))
			skel_control = skeleton_module && skeleton_module.control_path()
			out.puts(load_css(skel_control, skeleton, skin_name))
			
		# Get the CSS for a module
		else
			
			# get css from both the control and layout directories in the module.
			mod = SiteModuleBase.get(module_name) || SiteModuleBase.get(SiteModuleBase.module_name(module_name))			
			layout_path = mod && mod.layout_path()
			
			if (layout_path && File.directory?(layout_path) && !mod.skeleton?)
				out.puts(load_css(layout_path, skeleton, skin_name))
			end
			control_path =  mod && mod.control_path()
			if (control_path && File.directory?(control_path) && !mod.skeleton?)
				out.puts(load_css(control_path, skeleton, skin_name))
			end
			
		end
		
	end

	#TODO: Tie the css parser generator into this step.
	def load_css(path, skeleton, skin)
		
		sio = StringIO.new
		file_selector = File.join(path, "**", "*.css");

		if(site_module_loaded?(:Profile))
			user_skin = Profile::UserSkin.new();
			user_skin.init_from_site_theme(skin)
		end
		
		skin_values = SkinMediator.request_all_values(skeleton, skin)
		Dir[file_selector].each{|file|
			
			sio.puts "/*************** begin #{file.to_s} ***************/\n\n"
			begin
				t = CSSTrans::instance(file)

				t.static_files_url = $site.static_files_url
				
				skin_values.each_pair{|key, value|
					t.send(:"#{key}=", value);
					if (key =~ /color/)
						t.send(:"#{key}_img_url=", $site.colored_img_url(value))
					end
				}

				user_skin.each_pair{|key, value|
					t.send(:"#{key}=", value);
					if (value =~ /^#[0-9a-fAF]{6}$/)
						t.send(:"#{key}_img_url=", $site.colored_img_url(value))
					end
				};
				
				sio.puts CSSTrans::embed_icons(t.display())
			rescue
				$log.error("Error in CSS #{file.to_s}: #{$!}")
				$log.exception
				sio.puts "/* Error in file. */\n"
			end
			sio.puts "/*************** end #{file.to_s} ***************/\n"
		}
		return sio.string
	end

	def combo_script_js(ident, modname_match)
		# Don't try to write info message info out with a javascript file
		request.reply.headers["X-info-messages-off"] = true	
		
		modnames = modname_match[1].split('-')
		# redirect to update user cache
		if( $site.config.environment != :dev )
			res = modname_match[0]
			ident = check_ident(res, $site.digest_db[:script], ident)			
			site_redirect(url/ident/:script/res, :Static, 303) unless ident.nil?
		end

		reply.headers["Content-Type"] = MimeType::JavaScript

		static_cache("/script/#{modname_match[0]}") { |out|
			modnames.each {|modname|
				script_js(modname, out)
			}
		}
	end

	# Given the path script/module.js, loads all JavaScript files from
	# module/script/*.js.
	def script_js(modname, out)
		mod = SiteModuleBase.get(modname) || SiteModuleBase.get(SiteModuleBase.module_name(modname));

		if mod.nil?
			request = "/script/#{modname}.js"
			$log.error("SiteModuleBase (#{modname}) not found: #{request}")
			return
		end

		script_path = mod.script_path();
		site_values = mod.script_values;

		if (!site_values.empty? || script_path)
			if (File.directory?(script_path))
				out.print("#{mod.name}Module=#{site_values.to_json};\n")
				out.print("#{mod.script_function_string}\n");
				if (mod.name.to_sym == :Core)
					out.print("Site = CoreModule;\n");
				end

				if(script_path && File.directory?(script_path))
					Dir["#{script_path}/**/*.js"].sort.each {|file|
						output_script_file(out, script_path, file)
					}
				end
			end
		end
	end
	
	def output_script_file(out, script_path, file)
		@read_files ||= []
		if (@read_files.include?(file))
			return
		else
			@read_files << file
			
			file_obj = File.new(file)
			first_line = file_obj.readline
			prescanned = ""
			# preprocessor directive to include a file // require myscript.js
			while (first_line =~ /\/\/\s*require ([a-zA-Z_\-0-9\.]+\.js)/)
				$log.trace "#{file} is requiring #{script_path}/#{$1}"
				output_script_file(out, script_path, "#{script_path}/#{$1}")
				prescanned += first_line
				first_line = file_obj.readline
			end
			out.print(prescanned)
			out.print(first_line)
			out.print(file_obj.read + "\n")
		end
	end
end
