lib_require :Core, "storable/storable", "users/locs"

class School < Storable
	init_storable(:configdb, "schools");
	extend TypeID

	relation :singular, :location, [:loc], Locs

	def extra
		extra_str = ""
		if(!location.nil?)
			extra_str = location.name_path
		end
		
		return "#{extra_str}"
	end
	
	def slugline_safe
		return self.slugline || self.school_id
	end
end