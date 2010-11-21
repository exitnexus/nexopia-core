lib_require :Core, "storable/storable", "users/school", "users/user"

class SchoolRequest < Storable
	init_storable(:configdb, "school_requests");

	relation :singular, :school, [:school_id], School
	relation :singular, :user, [:userid], User
end