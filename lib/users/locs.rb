lib_require :Core, "storable/storable";

class Locs < Cacheable
	init_storable(:configdb, "locs");
	extend TypeID
	
	register_selection :id, :id

	relation :multi, :direct_children, [:id], Locs, { :index => :parent, :extra_columns => [:parent] }	
	relation :count, :direct_children_count, [:id], Locs, { :index => :parent, :extra_columns => [:parent] }

	# include Hierarchy;
	# init_hierarchy("All Locations");
	def name_path
		@name_path = self.get_parent_properties("name") * ", " if(!@name_path)
		return @name_path
	end


	def modifier
		return nil if self.type == 'N'
		
		if(!@modifier)
			name_parts = self.get_parent_properties("name")
			type_parts = self.get_parent_properties("type")

			if(self.type == 'S')
				mod_index = type_parts.index('N')
			else
				mod_index = type_parts.index('S') || type_parts.index('N')
			end
			
			@modifier = mod_index ? name_parts[mod_index] : nil
		end

		return @modifier
	end


	def augmented_name
		self.modifier ? self.name + ", " + self.modifier : self.name
	end


	def get_parent_properties(property_name)
		ret = [];

		self.parents.each { |parent_loc|
			ret << parent_loc.send(property_name);
		}

		return ret;
	end

	def parents
		if(self.parent == 0)
			return [self]
		else
			parent = Locs.find(:first, self.parent)
			return [self] + parent.parents
		end
	end

	def children
		if(!self.children?)
			return [self]
		else
			all_children = []
			self.direct_children.each { |child|
				all_children = all_children + child.children
			}

			return [self] + all_children
		end
	end

	def self.children_ids(base_id)
		location_ids = $site.memcache.get("sub_locations-#{base_id}")
		if (location_ids.nil?)
			direct_children_ids = Locs.db.query("SELECT id FROM locs WHERE parent = ?", base_id)
			all_children = []
			direct_children_ids.each {|child|
				all_children += self.children_ids(child['id'].to_i)
			}
			location_ids = [base_id] + all_children
			$site.memcache.set("sub_locations-#{base_id}", location_ids)
		end
		return location_ids
	end

	def children?
		return self.direct_children_count > 0
	end

	def extra
		return 'Country' if self.type == 'N'
		
		if(!@extra)
			name_parts = self.get_parent_properties("name")
			type_parts = self.get_parent_properties("type")

			mod_index = type_parts.index('N')
			@extra = (mod_index.nil? || name_parts[mod_index] == self.modifier) ? nil : name_parts[mod_index]
		end
		
		return @extra
	end	

	def to_s
		return self.name
	end
	
	def slugline_safe
		return self.slugline || self.id
	end
end
