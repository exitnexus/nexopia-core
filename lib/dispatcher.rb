

module Dispatcher
	SLEEP_BETWEEN_BATCHES = 0.3
	TERM_RETRIES = 4
	BATCH_SIZE = 10

	# Kill all children in the pids list, forcefully if needed
	def self.kill_children(pids, name = "child")
		pids.compact!

		# We'll try sending TERM to children in batches of ten.
		# If a child survives TERM for too long, we'll send a KILL
		# (and assume the kill is successful).  This guarantees we
		# will complete and hopefully will cause the children to die
		# gracefully.

		pid_group = Hash.new # pid => times killed
		repopulate_pid_group(pid_group, pids)
		while (!pid_group.empty?)
			kill_pids(pid_group, name, 'SIGTERM')
			sleep(SLEEP_BETWEEN_BATCHES) # Wait a bit for children to shut down

			# Check whether each process has died and remove the ones that no longer
			# exist from pid_group.
			pid_group.dup.each_key {|pid|
				if (pid && (Process.wait(pid, Process::WNOHANG) == pid))
					pid_group.delete(pid)
					$log.trace("#{name} process #{pid} killed successfully")
				end
			}

			# Okay, are we tired of sending TERM to any of the children?
			kill_group = Hash.new
			pid_group.each_key {|pid|
				if ((pid_group[pid] += 1) > TERM_RETRIES)
					kill_group[pid] = 0
				end
			}
			# Kill them and remove them from our list of pids
			unless kill_group.empty?
				kill_pids(kill_group, name, 'SIGKILL')
				pid_group.delete_if { |pid, term_times|
					term_times > TERM_RETRIES
				}
			end

			repopulate_pid_group(pid_group, pids)
		end
	end

	# Move entries from the pids array into the pid_group to ensure we
	# have ten entries in pid_group.
	def self.repopulate_pid_group(pid_group, pids)
		need = BATCH_SIZE - pid_group.length
		for i in 0...need
			pid = pids.delete_at(0)
			pid_group[pid] = 0 unless pid.nil?
		end

		return pid_group
	end

	#kill the processes
	def self.kill_pids(pids, name = "child", sig = "SIGTERM")
		pids.each_key {|pid|
			if(pid)
				$log.trace("Killing #{name} process #{pid} with #{sig}")
				begin
					Process.kill(sig, pid)
				rescue Errno::ESRCH
					$log.warning("Process #{pid} did not exist.")
				end
			end
		}
	end

	# Check if a process exists by sending it a dummy signal (signal 0) and
	# checking the return code.
	def self.process_exists?(pid)
		if (pid.nil?)
			# A nil process ID shall never exist.
			return false
		end
		begin
			return_value = Process.kill(0, pid)
			# No exceptions raised.  The process exists.
			return true
		rescue Errno::EPERM
			# No permission to access that PID.  Therefore it exists.
			return true
		rescue Errno::ESRCH
			# Process not found, therefore it does not exist.
			return false
		end
		throw "Could not check the status of #{pid}: #{$!}"
	end
end
