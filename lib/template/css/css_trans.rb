lib_require :core, 'template/css/csstrans.ErrorStream'
lib_require :core, 'template/css/csstrans.Parser'
lib_require :core, 'template/css/csstrans.Scanner'
lib_require :core, 'template/code_generator'
lib_require :core, 'template/generated_cache'
lib_require :core, 'lrucache', 'pagehandler'

require 'md5'

module CSSTrans
	
	MAX_EMBED = 8 * 1024 # Largest image willing to embed

	def self.get_file_path(mod, css_file)
		f = "#{$site.config.site_base_dir}/#{mod.to_s.downcase}/#{css_file}.css";
	end

	def self.get_name(mod, css_file)
		name = Cache.prefix + "_" + mod.to_s.upcase + "_" + css_file.gsub('/','_DIR_').gsub(/[^a-zA-Z0-9]/, "_").upcase;
	end

	class Cache < GeneratedCodeCache
		def self.instance(*args)
			return CSSTrans::from_file(*args)
		end

		def self.library
			Dir["core/lib/template/css/*.rb"];
		end
		def self.prefix
			"CSS";
		end
		
		def self.parse_dependency(dependency)
			return dependency.split(":");
		end
	
		def self.parse_source_file(_module, file_base)
			"#{_module}/#{file_base}.css"
		end
		
		def self.class_name(_module, file_base)
			"#{prefix}_#{_module.to_s.upcase}_#{file_base.gsub('/','_DIR_').gsub(/[^\w]/, '_').upcase}"
		end

		def self.output_file(_module, file_base)
			"generated/#{prefix}_#{_module.to_s.upcase}_#{file_base.gsub('/','_DIR_').gsub(/[^\w]/, '_').upcase}.gen.rb"
		end
		
		def self.source_dirs(mod)
			["#{mod.directory_name}"]
		end
		def self.source_regexp()
			/((?:layout|control)\/[^.\/]+).css$/
		end

		@@instantiatedClasses = {};
		def self.instantiatedClasses
			return @@instantiatedClasses;
		end

		@@instantiatedUserClasses = {};
		def self.instantiatedUserClasses
			return @@instantiatedUserClasses;
		end
	end
	
	def self.from_file(mod, css_file)
		name = get_name(mod, css_file);
		f = get_file_path(mod, css_file);
		#FileChanges.register_file(f);
		file = File.basename(f)
		dir = File.dirname(f)

		css_string = File.open(f).read();
		return CSSClass.new(name, f, [mod, css_file], css_string);
	end
	
	# Delete a file, but don't raise an error if the file does not
	# exist.
	public; def self.delete_quietly(filename)
		begin
			File.delete filename
		rescue Errno::ENOENT
			# We don't care if we couldn't delete the file
		end
	end

	public; def self.instance(css_file)
		css_file =~ /^(\w+)\/(.+).css$/
		mod,file = $1,$2
		if (!Cache.instantiatedClasses[[mod, file]])
			start_time = Time.now.to_f
			CSSTrans.from_file(mod,file);
			duration = Time.now.to_f - start_time
			$log.info("Generated #{css_file} in #{'%.4f' % duration} seconds", :template);
		elsif ($site.config.environment == :dev)
			$log.trace("Checking cache... #{css_file}", :template);
			fname = get_file_path(mod, file)
			if (File.exists?(fname))
				if !Cache::check_cached_file(fname, Cache::get_cached(mod,file), Time.at(0))
					# File is old, remove it (and associated _user_skin file)
					deletename = get_name(mod, file);
					CSSTrans.delete_quietly "#{$site.config.generated_base_dir}/#{deletename}.gen.rb"
					CSSTrans.delete_quietly "#{$site.config.generated_base_dir}/#{deletename}_user_skin.gen.rb"
					CSSTrans.from_file(mod,file);
				end
			end
		end
		$log.trace("Instantiating... #{css_file}", :template);
		return Cache.instantiatedClasses[[mod, file]].new();
	end
	
	public; def self.user_instance(css_file)
		css_file =~ /^(\w+)\/(.+).css$/
		mod,file = $1,$2
		if(!Cache.instantiatedUserClasses[[mod, file]])
			CSSTrans.from_file(mod, file);
		elsif ($site.config.environment == :dev)
			$log.trace("Checking cache... #{css_file}", :template);
			fname = get_file_path(mod, file)
			if (File.exists?(fname))
				if !Cache::check_cached_file(fname, Cache::get_cached(mod,file), Time.at(0))
					# File is old, remove it (and associated _user_skin file)
					deletename = get_name(mod, file);
					CSSTrans.delete_quietly "#{$site.config.generated_base_dir}/#{deletename}.gen.rb"
					CSSTrans.delete_quietly "#{$site.config.generated_base_dir}/#{deletename}_user_skin.gen.rb"
					CSSTrans.from_file(mod,file);
				end
			end
		end
		return Cache.instantiatedUserClasses[[mod, file]].new();
	end

	def self.parse_css(str)
		e_str = CSS::ErrorStream.new();
		css_scan = CSS::Scanner.new();
		css_scan.InitFromStr(str, e_str);
		css_parser = CSS::Parser.new(css_scan);	
		return css_parser.Parse();	
	end
	
	def self.embed_icons(content)
		# Want to embed icons, etc., all of which should appear in a
		# url(somethingsomethingsomething) bit.
		return content.gsub(/^(\s*)(.*)url\s*\(\s*['"](.*)['"]\s*\)(.*)/) { |match|
			# $1 is the prefix before the url bit,
			# $2 is the url itself, stripped of enclosing ' or " chars
			# $3 is the bit after the url.
			prefix_spaces = $1
			prefix = $2
			url = $3
			suffix = $4
			
			if suffix.include?('}')
				# This should never happen.  We plan on splitting this
				# css line into two lines, and it isn't really safe to
				# do that if we are closing a CSS rule.  We'd end up with
				# an unmatched }.  So don't try to change this line.
				match
			else
				@@lrucache = LRUCache.new(128) if (!defined?(@@lrucache))
				encoded, content_type, too_long = @@lrucache[url]
				if (encoded.nil? && !too_long)
					# Not in the cache, pull the file to embed
					url_parts = $site.url_to_area(url)
					if (url_parts[0] && !PageHandler.current.nil?)
						out = StringIO.new()
						req = PageHandler.current.subrequest(out,
						 	:GetRequest, url_parts[1], nil, url_parts[0])
						if (req.get_reply_ok())
							# base-64 encode the icon
							encoded = Base64.encode64(req.get_reply_output)
							encoded.gsub!(/\n/, '')
							content_type = req.reply.headers['Content-Type']
							# Want to skip embedding if the icon is too large
							if (encoded.length > MAX_EMBED)
								too_long = true
								encoded = nil
							else
								too_long = false
							end
							@@lrucache[url] = [encoded, content_type, too_long]
						end
					end
				end # if (encoded.nil?)

				if (!encoded.nil? && !content_type.nil?)
					# Have data to embed!
					# Hash the url because IE doesn't like Locations that are too long
					image_name = MD5::md5(url).to_s
					# First, the inline encoded image for all sane browsers
					mhtml = "#{prefix_spaces}#{prefix}url(\"data:#{content_type};base64,#{encoded}\")#{suffix} /* Normal browsers */\n"
					# Now, we just leave the URL alone for IE6/IE7.
					mhtml += "#{prefix_spaces}*#{prefix}url(#{url})#{suffix} /* MSIE 6, 7 targeted with the star hack */"
					mhtml
				else
					# Can't figure it out, leave unaltered
					match
				end
			end # if suffix.include?
		} # content.gsub
	end
	
	class CSSClass
		# class_name is the ruby class name of the class to be generated
		# source_name is the full path to the source template file
		# symbol used to look it up in the hash
		# source a string containing css to be parsed
		private; def initialize(class_name, source_name, symbol, source)
			@name = class_name;
			@source_name = source_name;
			@css_string = source;
			
			@vars = Hash.new;
			filename = "#{class_name}.gen.rb"
			filename_user_skin = "#{class_name}_user_skin.gen.rb"
			if (File.exists?(filename))
				# Already exists, just load it
				load(filename)
				load(filename_user_skin)
			else
				# Need to generate it
				parse();
			end
			Cache.instantiatedClasses[symbol] = CSSTrans.const_get(@name);
			Cache.instantiatedUserClasses[symbol] = CSSTrans.const_get(:"#{@name}_user_skin");
		end

		# Completely parse the CSS document and generate the class associated with it.
		private; def parse
			@doc = CSSTrans::parse_css(@css_string);
			@code = CodeGenerator.new(@name);
			@user_skin_code = CodeGenerator.new(:"#{@name}_user_skin")
			
			@doc.keys.each{|selector|
				user_skin_in_selector = false
				selector_string = ""
				selector.each_with_index{|sel,i|
					if (sel.kind_of? Array)
						selector_string += sel.join("")
					else
						selector_string += sel
					end
				}
				selector_string += "{\n"
				@code.append_print selector_string
				@doc[selector].each{|rule|
					prop, v = rule;
					user_skin_rule = false
					rule_name = "	#{prop}:"

					#TODO: Make this more generic so it can be applied to properties other than background image. For today, this is good enough.
					if(prop.to_s() == "ext-background")
						#DEPRECATED! Use background: $page_background_color $page_background_image
						rule_name = " background-color:"
						@code.append_conditional_print("@page_background_image", "background-image:", "@page_background_image");
					end
					if(prop.to_s() == "opacity")
						ie_val = v.to_s.to_f*100
						@code.append_print("\tzoom: 1;\n")
						@code.append_print("\tfilter: alpha(opacity = #{ie_val.to_i});\n")
						@code.append_print("\t-ms-filter: \"progid:DXImageTransform.Microsoft.Alpha(Opacity=#{ie_val.to_i})\";\n")
					end
					if(prop.to_s() == "min-height")
						min_height = v.to_s[0, -2].to_i #the min-height without px at the end
						@code.append_print("\t_height: expression( this.scrollHeight < #{min_height} ? \"#{min_height}\" : \"auto\" );\n")
					end
					if(prop.to_s() == "max-height")
						max_height = v.to_s[0, -2].to_i #the max-height without px at the end
						@code.append_print("\t_height: expression( this.scrollHeight < #{max_height} ? \"#{max_height}\" : \"auto\" );\n")
					end
					if(prop.to_s() == "min-width")
						min_width = v.to_s[0, -2].to_i #the min-width without px at the end
						@code.append_print("\t_width: expression( this.scrollWidth < #{min_width} ? \"#{min_width}\" : \"auto\" );\n")
					end
					if(prop.to_s() == "max-width")
						max_width = v.to_s[0, -2].to_i #the max-width without px at the end
						@code.append_print("\t_width: expression( this.scrollWidth < #{max_width} ? \"#{max_width}\" : \"auto\" );\n")
					end
					
					#hack to make inline-block work cross browser
					if(prop.to_s == "display" && v.to_s == "inline-block")
						@code.append_print("\tdisplay: -moz-inline-block;\n")
						@code.append_print("\tzoom: 1;\n")
						@code.append_print("\tdisplay: inline-block;\n")
						@code.append_print("\t_display: inline;\n")
						next #jump out here because we know there is nothing else to do for this rule
					end
					
					@code.append_print rule_name
					
					rule_value = ""
					v.each_with_index{|value,index|
						if (index > 0)
							rule_value += ","
						end
						value.each{|sub_value|
							sub_value = sub_value.join(" ")
							user_skin_rule = true if (sub_value.match(/\@/))
							sub_value = sub_value.gsub(/(\$|\@)[a-zA-Z1-9_]*/){|m|
								'#{@' + m[1..-1] + '}';
							}
							sub_value.gsub!('"', '\"');
							rule_value += " #{sub_value}";
						}
					}
					if (user_skin_rule)
						unless (user_skin_in_selector)
							@user_skin_code.append_print(selector_string)
							user_skin_in_selector = true
						end
						@user_skin_code.append_print(rule_name)
						@user_skin_code.append_print(rule_value)
						@user_skin_code.append_print(";\n")
					end
					@code.append_print(rule_value)
					@code.append_print(";\n")
				}
				if (user_skin_in_selector)
					@user_skin_code.append_print("}\n")
				end
				@code.append_print("}\n")
			}
			@code.generate(@source_name);
			@user_skin_code.generate(@source_name)
		end
		
		def to_str(css_set)
		end

	end
	
	
end
