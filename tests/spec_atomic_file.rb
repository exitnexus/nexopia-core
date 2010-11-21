lib_require :Core, 'atomic_file'

describe AtomicFile do
	ATOMIC_FILE_NAME = 'atomic_file.txt'
	
	def unlink(filename)
		File::unlink("#{$site.static_file_cache}/#{filename}")
	end
	
	it "should allow creating an atomic file" do
		begin
			file = AtomicFile::create(ATOMIC_FILE_NAME) { |out|
				out.print('hello, world')
			}
			line = file.gets
			line.should == 'hello, world'
		ensure
			unlink ATOMIC_FILE_NAME
		end
	end
	
	it "should allow creating multiple atomic files" do
		begin
			# Write
			for i in 0..99
				AtomicFile::create("#{i}_#{ATOMIC_FILE_NAME}") { |out|
					out.print i
				}
			end
		
			# Read back
			for i in 0..99
				filename = "#{$site.static_file_cache}/#{i}_#{ATOMIC_FILE_NAME}"
				file = File::new(filename, 'r')
				line = file.gets
				line.should == i.to_s
			end
		ensure
			for i in 0..99
				unlink "#{i}_#{ATOMIC_FILE_NAME}"
			end
		end
	end
	
	it "should work across threads" do
		# Green threads, not a great test
		begin
			# Write
			threads = Array.new
			for thread_num in 0..99
				threads << Thread.new(thread_num) { |i|
					AtomicFile::create("#{i}_#{ATOMIC_FILE_NAME}") { |out|
						out.print i
					}
				}
			end
			threads.each { |a_thread| a_thread.join }
		
			# Read back
			for i in 0..99
				filename = "#{$site.static_file_cache}/#{i}_#{ATOMIC_FILE_NAME}"
				file = File::new(filename, 'r')
				line = file.gets
				line.should == i.to_s
			end
		ensure
			for i in 0..99
				unlink "#{i}_#{ATOMIC_FILE_NAME}"
			end
		end
	end
	
	it "should not overwrite an existing file" do
		begin
			filename = "#{$site.static_file_cache}/#{ATOMIC_FILE_NAME}"
			FileUtils::mkdir_p(File::dirname(filename))
			file = File::new(filename, 'w')
			file.print('original')
			file.close
			file = AtomicFile::create(ATOMIC_FILE_NAME) { |out|
				out.print('replacement')
			}
			line = file.gets
			line.should == 'original'
		ensure
			unlink ATOMIC_FILE_NAME
		end
	end
	
	it "should allow us to get file information" do
		begin
			file = AtomicFile::create(ATOMIC_FILE_NAME) { |out|
				out.print('hello, world')
			}
			file.path.should == "#{$site.static_file_cache}/#{ATOMIC_FILE_NAME}"
		ensure
			unlink ATOMIC_FILE_NAME
		end
	end
	
end