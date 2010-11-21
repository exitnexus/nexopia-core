module Core
	class RunScripts
		# Pass in a prefix or set of prefixes to run.
		def self.run(prefixes, should_fork = false, status = nil)
			runfiles = [];
			prefix_found = false;
			prefixes.each {|type|
				prefix_found = false;
				site_modules {|mod|
					Dir["#{mod.run_path}/#{type}*.rb"].each {|file|
						if (File.ftype(file) != 'directory')
							runfiles.push(file);
							prefix_found = true;
						end
					}
				}
				if(!prefix_found)
					$log.error("Run script '#{type}' not found in any module.", :run);
					raise ArgumentError.new("Script '#{type}' not found");
				end
			}

			run = proc {
				if (should_fork)
					$log.info("Executing runscript(s) #{runfiles.join(', ')} in forked process #{Process.pid}", :run)
				else
					$log.info("Executing runscript(s) #{runfiles.join(', ')}", :run)
				end
				start = Time.now
				errors = 0
				
				instance = Thread.current[:run_script_runner] = self.new
				begin
					runfiles.each {|file|
						begin
							if (should_fork)
								$0 = "nexopia-runner task:#{file}"
							end
							$site.cache.use_context(nil) {
								instance.run_script(file)
							}
						rescue
							errors = errors + 1
							$log.error("Run script #{file} failed with error", :run)
							$log.exception()
						end
					}
				ensure
					if (should_fork)
						$log.info("Finished executing runscript(s) #{runfiles.join(', ')} in forked process #{Process.pid}. Execution time was #{'%.4f' % (Time.now.to_f - start.to_f)}s", :run)
					else
						$log.info("Finished executing runscript(s) #{runfiles.join(', ')}.  Execution time was #{'%.4f' % (Time.now.to_f - start.to_f)}s", :run)
					end
					Thread.current[:run_script_runner] = nil
				end
				return (-1 * errors)
			}
			if (should_fork)
				rv = fork(&run)
			else
				rv = run.call
			end
			if (rv.nil?)
				rv = 0
			end
			return rv
		end
		
		if (site_module_loaded? :Worker)
			register_task CoreModule, :run, :lock_time => 120
		end

		def initialize()
			@regex = /([^-\/]+)-(.+)\.rb$/;
			@running = nil;
			@running_info = {};
			@depth = 0;
			@ran = {};
		end

		def run_script(file)
			@running, file = file, @running; # swap them so we can restore them after this is done.

			res = @running.match(@regex);

			if(!res)
				$log.error("#{@running} not found, must be named as category-task.rb", :run)
				exit 1
			end

			info = {:type => res[1], :name => res[2]};

			@running_info, info = info, @running_info;

			begin
				if (!@ran.key?(@running))
					@ran[@running] = true;
					$log.info("#{'|'*@depth}Running #{@running_info[:type]}-#{@running_info[:name]}...", :run);
					require(@running);
				end
			ensure
				@running, file = file, @running; # swap back
				@running_info, info = info, @running_info;
			end
		end
		def depends_on(name)
			new_file = @running.sub(@regex, '\1-' + name + '.rb');
			@depth += 1;
			$log.trace("#{'|'*@depth}#{@running_info[:type]}-#{@running_info[:name]} depends on #{@running_info[:type]}-#{name}", :run);
			run_script(new_file);
			@depth -= 1;
		end
	end
end

def depends_on(name)
	runner = Thread.current[:run_script_runner]
	if (!runner)
		raise "Must be inside a runscript to call depends_on"
	end
	
	runner.depends_on(name)
end
