lib_require :Blogs, 'blog_post'

describe MemCache do
	SPEC_MEMCACHE_EXPIRE = 60
	SPEC_MEMCACHE_KEY = 'spec_memcache'
	SPEC_MEMCACHE_LOTS = 20480
	
	before(:each) do
		$site.memcache.flush_all
	end
	
	after(:each) do
		$site.memcache.flush_all
	end
	
	it 'should allow adding a numeric value' do
		$site.memcache.set(SPEC_MEMCACHE_KEY, 1, SPEC_MEMCACHE_EXPIRE)
		$site.memcache.get(SPEC_MEMCACHE_KEY).should == 1
	end

	it 'should allow adding a string value' do
		$site.memcache.set(SPEC_MEMCACHE_KEY, 'hello!', SPEC_MEMCACHE_EXPIRE)
		$site.memcache.get(SPEC_MEMCACHE_KEY).should == 'hello!'
	end

	it 'should allow adding a string value that is url-encodeable' do
		s = 'hello, world!'
		URI::encode(s).should_not == s
		$site.memcache.set(SPEC_MEMCACHE_KEY, s, SPEC_MEMCACHE_EXPIRE)
		$site.memcache.get(SPEC_MEMCACHE_KEY).should == s
	end

	it 'should allow adding an array value' do
		a = [ 1, 2, 'three', 4.0 ]
		$site.memcache.set(SPEC_MEMCACHE_KEY, a, SPEC_MEMCACHE_EXPIRE)
		$site.memcache.get(SPEC_MEMCACHE_KEY).should == a
	end

	it 'should allow adding a hash value' do
		h = { :a => 'a', :b => 'bee', :c => 123 }
		$site.memcache.set(SPEC_MEMCACHE_KEY, h, SPEC_MEMCACHE_EXPIRE)
		$site.memcache.get(SPEC_MEMCACHE_KEY).should == h
	end
	
	it 'should handle compressible value' do
		s = "s" * 40960
		$site.memcache.set(SPEC_MEMCACHE_KEY, s, SPEC_MEMCACHE_EXPIRE)
		$site.memcache.get(SPEC_MEMCACHE_KEY).should == s
	end
	
	it 'should handle blog posts' do
		blog_post = Blogs::BlogPost::find(:first, :conditions => ['userid = ?', 3233577])
		blog_post.nil?.should == false
		$site.memcache.set(SPEC_MEMCACHE_KEY, blog_post, SPEC_MEMCACHE_EXPIRE)
		$site.memcache.get(SPEC_MEMCACHE_KEY).should == blog_post
	end

	it 'should be able to check_and_add a new key' do
		$site.memcache.delete('spec_memcache_1')
		$site.memcache.check_and_add('spec_memcache_1', 1).should == true
	end
	
	it 'should not allow check_and_add to add a duplicate key' do
		$site.memcache.delete('spec_memcache_2')
		$site.memcache.check_and_add('spec_memcache_2', 1).should == true
		$site.memcache.check_and_add('spec_memcache_2', 1).should == false
	end
	
	it 'should timeout and allow adding duplicate key' do
		$site.memcache.delete('spec_memcache_3')
		$site.memcache.check_and_add('spec_memcache_3', 1).should == true
		$site.memcache.check_and_add('spec_memcache_3', 1).should == false
		sleep 2
		$site.memcache.check_and_add('spec_memcache_3', 1).should == true
	end
	
	it 'should allow setting lots of keys at once' do
		pairs = Hash.new
		for i in 1..SPEC_MEMCACHE_LOTS
			pairs["spec_memcache-#{i}"] = i
		end
		$site.memcache.set_many(pairs, SPEC_MEMCACHE_EXPIRE)
	end
	
	it 'should allow getting lots of keys at once' do
		# First, store some values
		pairs = Hash.new
		for i in 1..SPEC_MEMCACHE_LOTS
			pairs["spec_memcache-#{i}"] = i
			GC.start if (pairs.size % 1024) == 0
		end
		$site.memcache.set_many(pairs, SPEC_MEMCACHE_EXPIRE)
		
		# Now, retrieve them
		keys = Array.new
		pairs.each { |k, v|
			keys << k
		}
		$site.memcache.get(*keys).should == pairs.map { |k, v| v }
	end
	
	it 'should allow loading lots of keys at once' do
		# First, store some values
		pairs = Hash.new
		for i in 1..SPEC_MEMCACHE_LOTS
			pairs["spec_memcache-#{i}"] = i
			GC.start if (pairs.size % 1024) == 0
		end
		$site.memcache.set_many(pairs, SPEC_MEMCACHE_EXPIRE)

		# Now, retrieve them
		keys = Array.new
		for i in 1..SPEC_MEMCACHE_LOTS
			keys << [i.to_s]
		end
		retrieved = $site.memcache.load('spec_memcache', keys,
		 	SPEC_MEMCACHE_EXPIRE) {
			# Nothing in block
		}
		
		retrieved.should == pairs
	end
	
	it 'should allow loading with missing keys' do
		# First, store some values
		pairs = Hash.new
		for i in 1..256
			pairs["spec_memcache-#{i}"] = i
		end
		$site.memcache.set_many(pairs, SPEC_MEMCACHE_EXPIRE)
		
		# Now, prepare some extra values
		for i in 257..512
			pairs["spec_memcache-#{i}"] = i
		end

		# Now, retrieve them
		keys = Array.new
		for i in 1..512
			keys << [i.to_s]
		end
		retrieved = $site.memcache.load('spec_memcache', keys,
		 	SPEC_MEMCACHE_EXPIRE) { |missing_keys|
			found_keys = Hash.new
			missing_keys.each { |k, v|
				found_keys[k] = k.first.to_i
			}
			found_keys
		}
		
		retrieved.should == pairs
	end
	
end