require 'yaml'
require 'core/lib/attrs/class_attr'
require 'core/lib/filechangemonitor'
require 'core/lib/dependency_config'
# This file defines some tools for requiring module libraries. This also allows
# you to simply 'want' a module instead of require it, and know whether or not
# it was actually included.

class ModuleError < SiteError
	def log_level()
		return :critical;
	end
end

class SiteModuleBase
	attr :name
	attr :dependency_config, true
	
	class ModuleDependsOn < SiteError
		attr :modname
		attr :required
		def initialize(modname, required)
			@modname = modname
			@required = required
		end
	end

	class << self
		def set_log_actions(actions)
			class_attr(:log_actions, true);
			self.log_actions = actions;
		end
	end
	set_log_actions({:none => 0});

	## this is a ghost. It's initialized below so Core can properly be bootstrapped
	## into the list.
	# @@module_objects = {};

	def initialize(name)
		@name = name.to_s;
		@dependency_config = DependencyConfig.new
	end

	# returns true if the system is in the process of loading modules.
	def SiteModuleBase.initializing?()
		return @initializing || false
	end

	def SiteModuleBase.tags=(*tags)
		@tags = @tags || []
		@tags += tags.flatten
		@tags.uniq!
	end
	def SiteModuleBase.tags
		@tags || []
	end
	def tags
		self.class.tags
	end
	def directory_name()
		SiteModuleBase.directory_name(@name)
	end
	def lib_path(lib, type = :lib)
		subpath = case type
			when :test then "tests/lib"
			else "lib"
		end

		return "#{directory_name}/#{subpath}/#{lib}";
	end
	def set_javascript_dependencies(mods)
		self.class.set_javascript_dependencies(mods)
	end
	def javascript_dependencies()
		self.class.javascript_dependencies()
	end
	def script_values()
		return {}
	end
	def script_function_string()
		return "";
	end
	
	def self.set_javascript_dependencies(mods)
		@javascript_dependencies = [*mods.compact];
	end
	def self.javascript_dependencies()
		all_dependencies = [];
		@javascript_dependencies.each{|mod|
			all_dependencies.concat(mod.javascript_dependencies + [mod]);
		} if @javascript_dependencies
		return all_dependencies.uniq
	end
	
	# This is called for each module after all modules have loaded. Overload
	# it to do things like auto-require libraries and the like.
	def after_load()
	end
	
	def script_path()
		return "#{directory_name}/script";
	end
	def layout_path()
		return "#{directory_name}/layout";
	end
	def control_path()
		return "#{directory_name}/control";
	end
	def static_path()
		return "#{directory_name}/static";
	end
	def skin_data_path()
		return "#{directory_name}/skindata";
	end
	def template_path()
		return "#{directory_name}/templates";
	end
	def run_path()
		return "#{directory_name}/run"
	end
	
	def tests_path()
		return "#{directory_name}/tests";
	end

	def skeleton?
		false
	end
	
	def to_s
		return @name
	end
	def to_sym
		return @name.to_sym
	end

	# call this when defining a module to place it in a meta-module group.
	# Only one module can occupy any given meta-module place, and only one's
	# pagehandlers will be loaded (but libs will be available).
	# You can specify which meta-module will be loaded by adding to the meta_modules
	# hash in the config.
	def SiteModuleBase.meta_module(name, default = nil)
		@meta_module = [name, default]
	end
	def SiteModuleBase.meta_module_info
		@meta_module
	end
	def meta_module_info
		self.class.meta_module_info
	end
	def is_meta(name)
		meta_module_info && meta_module_info[0] == name
	end

	def load_all_rb()
		libs = Dir["#{directory_name}/lib/*.rb"].collect.sort
		libs.each {|file|
			fname = file.split("/").last
			$log.spam("Auto-requiring #{fname}", :site_module);
			lib_require :"#{name}", fname;
		}
	end

	def SiteModuleBase.initialize_modules()
		@initializing = true
		if ($site.config.modules_include.nil?)
			mods = [*Dir["*"]].select{|name|
				name =~ /^[a-zA-Z][a-zA-Z0-9_]+$/
			}.sort.map{|name|
				SiteModuleBase.module_name(name).to_sym
			};
		else
			mods = $site.config.modules_include;
			if (!mods.include?(:Core))
				mods.unshift(:Core);
			end
		end

		@@mods_to_load = mods.collect {|name|
			name = SiteModuleBase.directory_name(name.to_s());
			case name
			when 'logs', 'config' then nil
			else
				if (File.directory?(name) &&
					!$site.config.modules_exclude.include?(SiteModuleBase.module_name(name).to_sym)
					)
					SiteModuleBase.module_name(name);
				else
					nil
				end
			end
		}.compact

		@@mods_to_load.each {|name_sym|
			# Note that name_sym is not an actual symbol -- it's
			# a string!  Don't blame me, *I* didn't do it...
			name = SiteModuleBase.directory_name(name_sym);
			
			# If there is a library named the same as the module,
			# we assume it contains a class named ModnameModule and that
			# this is the object that represents that module.
			lib_require :Core, "typeid"; # this needs to happen as late as possible.
			
			mod_class = nil;
			
			if Object.const_defined?(:"#{name_sym}Module")
				mod_class = Object.const_get(:"#{name_sym}Module") 
			else
				mod_class = Class.new(SiteModuleBase)
				Object.const_set(:"#{name_sym}Module", mod_class)
			end
			mod_class.extend(TypeID);

			begin
				if (File.file?("#{name}/lib/#{name}module.rb"))
					previous_module = @@current_module;
					@@current_module = name_sym.to_sym; 
					require "#{name}/lib/#{name}module.rb";
					@@current_module = previous_module;
				elsif(File.file?("#{name}/lib/#{name}_module.rb"))
					previous_module = @@current_module;
					@@current_module = name_sym.to_sym; 
					require "#{name}/lib/#{name}_module.rb";
					@@current_module = previous_module;
				end
			rescue ModuleDependsOn => dependency
				$log.trace("Module #{name} wants #{dependency.modname.to_s} loaded first. Changing load order", :site_module)
				# for now, just dump it to the back of the list of modules to load.
				if (!mods.include?(dependency.modname) && dependency.required)
					@@mods_to_load.push(dependency.modname.to_s)
					$log.warning("WARNING: #{name} requires #{dependency.modname.to_s}, which is not included in the @modules_include array of this config.  Make sure that this is correct.", :site_module)
				end
				@@mods_to_load.push(name_sym)
				next
			end

			begin
				mod_class = Object.const_get("#{name_sym}Module");
			rescue NameError
				# do a first initialization of the module
				mod_class = Object.const_set("#{name_sym}Module", Class.new(SiteModuleBase));
			end

			# Initialize an instance of that and add a typeid and javascript config to it
			mod_obj = mod_class.new(name_sym);
			if (mod_obj)
				# provides name and downcase version for fast lookup
				# NOTE: this is needed for url handling where modules are
				#       downcase encoded
				@@module_objects[name_sym] = mod_obj;
				@@module_objects_downcase[name_sym.downcase] = mod_obj;

				meta_info = mod_obj.meta_module_info
				if (meta_info)
					meta_name, meta_default = meta_info
					sym_name = name_sym.to_sym
					chosen = $site.config.modules_meta && $site.config.modules_meta[meta_name]
					if (((chosen && chosen == sym_name) || meta_default) &&
						!@@module_objects[name_sym])

						# provides name and downcase version for fast lookup
						@@module_objects[name_sym] = mod_obj
						@@module_objects_downcase[name_sym.downcase] = mod_obj;
					end
				end

				# Build a javascript and css dependency tree for the module if scripts/config.yaml exists
				begin
					yaml_file = "#{name}/config.yaml"
					if (File.file?(yaml_file))						
						mod_obj.dependency_config = YAML::load(File.open(yaml_file))
						mod_obj.dependency_config.config_module = name
					end
				rescue
					$log.error "Unable to load dependency config file: #{yaml_file}: #{$!}"
				end
				mod_obj.dependency_config.config_module = name

			end
			
			
		}
		@initializing = false
		
		self.loaded {|mod|
			mod.after_load()
		}

		return nil;
	end

	def SiteModuleBase.directory_name(mod_name)
		temp = mod_name.gsub(/([A-Z])/, '_\1');
		if(temp.index("_") == 0)
			temp = temp.slice(1,temp.length-1);
		end
		return temp.downcase();
	end
	
	def SiteModuleBase.module_name(dir_name)
		dir_parts = dir_name.split("_");
		mod_name = "";
		dir_parts.each{|part| mod_name << part.capitalize}
		return mod_name;
	end

	# Finds initialized module with specific _name_. When _downcase_lookup_
	# is +true+ then we search for downcased versions of module names.
	# Returns module object or +nil+
	def SiteModuleBase.get(name, downcase_lookup = false)
		return @@module_objects[name.to_s] unless downcase_lookup
		return @@module_objects_downcase[name.to_s]
	end

	def SiteModuleBase.to_be_loaded()
		return @@mods_to_load
	end

	def SiteModuleBase.loaded_modules()
		modules = []
		@@module_objects.each {|name, obj|
			modules << obj
		}
		return modules
	end

	def SiteModuleBase.loaded()
		@@module_objects.each {|name, obj|
			yield obj;
		}
	end
end

class CoreModule < SiteModuleBase
	tags = :core
end

class SiteModuleBase
	# bootstrap the CoreModule in.
	mod_name = "Core"
	mod = CoreModule.new(mod_name);

	# provides name and downcase version for fast lookup
	@@module_objects = {mod_name => mod};
	@@module_objects_downcase = {mod_name.downcase => mod};
end

module Kernel
	# Load module mod, if not already loaded, and then loads the library lib.
	# Fails loudly (throws ModuleError) if the module can't be loaded.
	# type is passed on to modobj.lib_path to help locate the file.
	def lib_require_type(type, mod, *libs)
		$require_depth ||= 0;
		$require_depth += 1;
		$log.spam("#{' '*$require_depth}Requiring #{mod}::#{libs.join(',')}", :site_module);
		if (!lib_want_internal(mod, *libs))
			if (SiteModuleBase.initializing?)
				mod_require(mod)
			else
				raise ModuleError, "Required module #{mod} was not available.";
			end
		end
		$log.spam("#{' '*$require_depth}Done.", :site_module);
		$require_depth -= 1;
	end

	# Load module mod, if not already loaded, and then loads the library lib.
	# Fails loudly (throws ModuleError) if the module can't be loaded.
	def lib_require(mod, *libs)
		lib_require_type(:lib, mod, *libs)
	end

	# Load module mod, if not already loaded, and then loads the library lib.
	# Returns false if the module can't be loaded. You can then use module_loaded?
	# to determine if it was successfuly loaded.
	# type is passed on to modobj.lib_path to help locate the file.
	def lib_want_type(type, mod, *libs)
		# Core is treated specially.
		if (modobj = site_module_get(mod))
			libs.each {|lib|
				FileChanges.register_file(modobj.lib_path(lib, type))
				require(modobj.lib_path(lib, type));
			}
			return true;
		else
			return false;
		end
	end

	# Load module mod, if not already loaded, and then loads the library lib.
	# Returns false if the module can't be loaded. You can then use module_loaded?
	# to determine if it was successfuly loaded.
	def lib_want_internal(mod, *libs)
		@@current_module ||= nil;
		previous_module = @@current_module;
		@@current_module = mod;
		return lib_want_type(:lib, mod, *libs)
	ensure
		@@current_module = previous_module;
	end

	def lib_want(mod, *libs)
		mod_want(mod)
		lib_want_internal(mod, *libs)
	end

	def site_module_loaded?(name)
		begin
			return Object.const_get("#{name}Module".to_sym) != nil;
		rescue NameError
			return false;
		end
	end

	def site_module_get(name)
		if (name.kind_of? Class)
			SiteModuleBase.loaded() {|mod|
				return mod if mod.class == name
			}
		elsif(!/^[A-Z]/.match(name.to_s))
			name = SiteModuleBase.module_name(name.to_s);
		end
		return SiteModuleBase.get(name);
	end

	def site_modules()
		SiteModuleBase.loaded() {|mod|
			yield mod;
		}
	end

	# call this at the begining of a module class to defer loading of the module
	# until after the module specified by modname has loaded. Requirement loops
	# are currently undefined behaviour.
	def mod_require(modname)
		if (modname.to_s.downcase == @@current_module.to_s.downcase)
			return
		end
		if (!site_module_get(modname))
			raise SiteModuleBase::ModuleDependsOn.new(modname, true)
		end
	end
	def mod_want(modname)
		if (modname.to_s.downcase == @@current_module.to_s.downcase)
			return
		end
		if (!site_module_get(modname) && SiteModuleBase.to_be_loaded.include?(modname.to_s))
			raise SiteModuleBase::ModuleDependsOn.new(modname, false)
		end
	end
end
