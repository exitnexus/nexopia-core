
# extract all modules that should be loaded
modules = Dir["core/lib/storable/relation_*.rb"].map {|path|
	"storable/#{File.basename(path, '.rb')}"
}

# require relation related modules
lib_require :Core, 'storable/relation', *modules

class RelationManager
	# When aggregating deletes, limit the maximum deferred deletes to this.
	MAX_DELETE_QUEUE_LENGTH = 1024
	
	class << self
		@@relation_prototypes = {} #used to store the prototypes for all relations
		
		#Defines a new prototype and registers it as a type of relation
		def create_prototype(name, type, origin, key_columns, target, *extra_args)
			rp = RelationPrototype.new(name, type, origin, key_columns, target, *extra_args)
			self.register_prototype(rp)
			return rp
		end
		
		#A prototype must be registered with the relation manager before it can be built
		#by storable.
		def register_prototype(prototype)
			@@relation_prototypes[[prototype.origin, prototype.name]] = prototype
		end
		
		#returns the prototype that matches origin and name if it exists, otherwise nil
		def get_prototype(origin, name)
			return @@relation_prototypes[[origin, name]]
		end
		
		#return a list of prototypes that are affected when an instance of table has changes in columns
		def find_prototypes(instance, columns=nil)
			return @@relation_prototypes.values.select {|prototype|
				prototype.match?(instance, columns)
			}
		end
		
		#The relation cache is used to store pointers to all existing relations.
		#It expires at the end of the page view.
		def relation_cache
			return $site.cache.get(:relation_manager_cache, :page) { Hash.new };
		end
		protected :relation_cache

		def test_reset(class_name)
			relation_cache.delete_if {|key, val| 
				key =~ /^#{class_name}/
			}
		end
		
		#Adds a relation to the relation manager internal cache (page duration)
		#If a relation already exists in the cache for the given cache key it is
		#returned instead and should be used to ensure object consistency.
		#Relation caching is critical to being able to invalidate relations when
		#objects enter/leave them.
		def cache_relation(relation, options)
			relation_cache[relation.cache_key] ||= {}
			relation_cache[relation.cache_key][options] ||= relation
			return relation_cache[relation.cache_key][options]
		end
		
		#Creates an instance of a relation using a relation prototype
		def create_relation(origin, name, instance, options)
			prototype = self.get_prototype(origin, name)
			relation = prototype.create_relation(instance, options) unless prototype.nil?
			if (relation)
				options_key = CGI::escape(options.to_s)
				unless options_key.empty?
					cache_key = prototype.cache_key(instance)
					@relation_options ||= {}
					@relation_options[cache_key] ||= {}
					@relation_options[cache_key][options_key] = true
				end
				return self.cache_relation(relation, options_key)
			else
				raise "Unable to locate relation #{origin}-#{name}"
			end
		end
		
		#invalidate all relations that are no longer valid for instance (takes instance's modification state into account)
		def invalidate_store(instance)
			modified_columns = instance.modified_columns
			prototypes = find_prototypes(instance, modified_columns)
			original_instance = instance.original_version
			#we want to invalidate the relations the object is leaving and the relations the object is entering
			prototypes.each {|prototype|
				invalidate_relation(prototype.cache_key(instance))
				invalidate_relation(prototype.cache_key(original_instance))
			}
		end
		
		#invalidate all relations that are no longer valid given that the instance is being deleted
		def invalidate_delete(instance)
			prototypes = find_prototypes(instance)
			original_instance = instance.original_version
			prototypes.each {|prototype|
				invalidate_relation(prototype.cache_key(original_instance))
			}
		end
		
		#delete both the internal and memcache versions the relations for cache_key
		def invalidate_relation(cache_key)
			if (relation_cache[cache_key])
				relation_cache[cache_key].each { |k, v|
					v.invalidate
				}
			end
			@delete_queue ||= nil
			if (@delete_queue.nil?)
				$site.memcache.delete(cache_key)
			else
				@delete_queue << cache_key
				if (@delete_queue.length > MAX_DELETE_QUEUE_LENGTH)
					@delete_queue.uniq.each { |key|
						$site.memcache.delete(key)
					}
					@delete_queue = Array.new
				end
			end
		end
		
		# User wants to aggregate a set of deletes.  This can happen if,
		# for example, we are about to delete a number of stories.  You
		# should pass a block to this method.  We queue up the memcache
		# deletes for the duration of the block and then execute them all
		# after completing the block.
		def aggregate_deletes
			@delete_queue ||= nil
			if (@delete_queue.nil?)
				@delete_queue = Array.new
				begin
					yield
				ensure
					@delete_queue.uniq.each { |key|
						$site.memcache.delete(key)
					}
					@delete_queue = nil
				end
			else
				# Already aggregating deletes
			end
		end
	end
end
