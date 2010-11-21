require 'fileutils'

# This class provides a means to create and populate a file
# atomically.  We will create a file under a temporary name
# (but, unlike TempFile, maintaining the correct extension),
# output contents, and then rename the file into place.
# That way, either the file exists and contains the proper
# contents, or the file does not exist.  We deliberately
# play fast-and-loose with filesystem issues.
class AtomicFile
	# Create the file and move it in to place atomically.
	# We take the name of the final file, and the directory
	# to create it in.  The temp file's name will be based
	# on the filename, but with a different prefix.
	# The caller must also pass in a block to actually
	# output the file contents.
	# We return either the newly created file or, if the
	# file already existed, we return a reference to that file.
	# Important note: We will NOT recreate the file if it
	# already exists, though we may create and destory a
	# temporary file.
	# We take steps to ensure that the temporary file has
	# a unique name, but do not fundamentally guarantee this.
	def self.create(filename, directory = $site.static_file_cache)
		if (filename[0] == '/'[0])
			file_path = "#{directory}#{filename}"
		else
			file_path = "#{directory}/#{filename}"
		end
		if ("#{File::dirname(file_path)}/".index(directory) != 0)
			raise ArgumentError("#{file_path} trying to break out of #{directory}")
		end

		# Ensure the directory is there
		actual_dir = File::dirname(file_path)
		actual_basename = File::basename(file_path)
		if (File::exists?(actual_dir))
			if (!File::directory?(actual_dir))
				raise ArgumentError::new("#{actual_dir} already exists but is not a directory")
			end
		else
			FileUtils::mkdir_p(actual_dir)
		end
		
		# Is the file already there?
		begin
			return File::new(file_path, 'r')
		rescue Errno::ENOENT
			begin
				# File not already there, create it as a temp
				temp_path = "#{actual_dir}/#{Process::pid}_#{(rand*100000).to_i}_#{actual_basename}"
				file = File::new(temp_path, 'w')
				# Populate it
				yield(file)
				file.close
			
				# And now rename it into place
				begin
					File::rename(temp_path, file_path)
				rescue Errno::EEXIST
					# May file due to race condition, in which case
					# someone else created the file.  That's fine, so
					# long as someone created it.
				end
				return File::new(file_path, 'r')
			ensure # Clean up temp file if it still exists
				begin
					File::unlink(temp_path)
				rescue Errno::ENOENT
					# Didn't exist, no matter; rename must have succeeded.
				end
			end
		end # Is the file already there?
	end
end # class AtomicFile
