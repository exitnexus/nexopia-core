# See SNEX-897.  We use the FileChangeMonitor class to dynamically reload source
# files that change, but only in a dev environment.  This means much of the
# time, we do NOT need to shut down and restart the ruby site when we make
# some minor changes.

class FileChangeMonitor
	def register_file(filename)
	end
	
	def changed()
		return Hash.new
	end
	
	def reload_changed()
	end
end

if ($site.config.environment == :dev)
	# Reopen to provide working implementations.
	class FileChangeMonitor
		def initialize()
			@files = {};
			@last_run = Time.now.to_f
		end

		def statfile(filename)
			stat = nil;
			begin
				stat = File.stat(filename);
			rescue Errno::ENOENT
				begin
					stat = File.stat("#{filename}.rb");
				rescue Errno::ENOENT
				end
			end
		end

		def register_file(filename)
			if (stat = statfile(filename))
				@files[filename] = stat;
			else
				$log.error "cannot find file #{filename}"
			end
		end

		def changed()
			retval = Hash.new

			# Run recently?
			now = Time.now.to_f
			if ((now - @last_run) < 5)
				return retval
			else
				@last_run = now
			end
	
			@files.each {|filename, oldstat|
				newstat = statfile(filename);
				if(!newstat) #missing, stop monitoring
					@files.delete(filename);
					retval[filename] = :deleted;
				elsif(oldstat.mtime != newstat.mtime) #changed
					@files[filename] = newstat;
					retval[filename] = :changed;
				end
			}
			return retval;
		end

		# Force the Ruby interpretor to reload any changed files.
		def reload_changed
			changed().each { |filename, change|
				if (change == :changed)
					begin
						stat = File.stat(filename);
						$log.info "Reloading #{filename}"
						load filename;
					rescue Errno::ENOENT, Errno::EISDIR
						begin
							stat = File.stat("#{filename}.rb");
							$log.info "Reloading #{filename}.rb"
							load "#{filename}.rb";
						rescue Errno::ENOENT
							$log.error "Unable to reload #{filename}"
						end
					end
				end
			}
		end
	end # FileChangeMonitor
end # if ($site.config.environment == :dev)

FileChanges = FileChangeMonitor.new();
