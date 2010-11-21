lib_require :Core, "users/locs", "users/school"

module Core
	class QueryHandler < PageHandler
		declare_handlers("core") {
			area :Public
			access_level :Any

			handle :GetRequest, :query_location, "query", "location"
			handle :GetRequest, :query_location, "query", "location", input(String)
			handle :GetRequest, :query_school, "query", "school"
			
			access_level :Admin, CoreModule, :createbanners
			handle :GetRequest, :query_sublocations, "query", "sublocations"
		}

		def query_location(type=nil)
			query_path = params["name", String, ""]

			$log.trace "Query String: #{query_path}"

			parts = query_path.split(",")
			query_path = parts[0]
			modifier = parts[1]

			if(type)
				conditions = ["type = ? AND name LIKE ?", type, "#{query_path}%"]
			else
				conditions = ["name LIKE ?", "#{query_path}%"]
			end

			# Might want to cache this in memory
			locations = Locs.find(:all, :scan, :conditions => conditions, 
				:order => "name",
				:limit => 30)
			
			# We're using a generated value to sort these, so we can't do it on the database level
			locations.sort! { |a,b| (a.modifier || "") <=> (b.modifier || "") }

			# Now get the matches where the path is in part of the path. Stop right away when we hit 10 (or if we've already hit it).
			if (modifier)
				modifier.strip!
				matches = []
				locations.each { |location|
					break if matches.length >= 10
					matches << location if location.modifier && !location.modifier.downcase.index(modifier.downcase).nil?
				}
				locations = matches
			end

			export_location_xml(request, locations)
		end


		def query_sublocations
			location_id = params["id", Integer, nil]
			
			location = Locs.find :first, location_id
			if (location.type == "C" || location.type == "S")
				sublocations = location.children
			else
				# Potentially too large a data set. Just send the location back
				location = Locs.find :first, 75 if location_id == 0 # switch with world if we're using 0 for the id
				sublocations = [location]
			end

			export_location_xml(request, sublocations)
		end
		
		
		def query_school			
			query_path = params["name", String, ""]
			location = params["loc", Integer, nil]

			$log.trace "Query String (School): #{query_path}"

			if(location)
				conditions = ["loc = ? AND name LIKE ? AND live = 'y'", location, "#{query_path}%"]
			else
				conditions = ["name LIKE ? AND live = 'y'", "#{query_path}%"]
			end

			# Might want to cache this in memory
			schools = School.find(:all, :scan, :conditions => conditions, 
				:order => "name",
				:limit => 30)
			
			export_school_xml(request, schools)
		end
		
		
		def export_location_xml(request, locations)
			request.reply.headers['X-info-messages-off'] = true			
			request.reply.headers['Content-Type'] = MimeType::XMLText

			xml_string = "<?xml version = \"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?>" + "<locations>"

			locations.each { |location| 
				extra_optional = location.extra ? "<extra>#{location.extra}</extra>" : ""
				query_sublocations = (location.type == "C" || location.type == "S") && location.children?
				xml_string = xml_string + 
					"<location query_sublocations='#{query_sublocations}'>" +
						"<name>#{location.augmented_name}</name>" + 
						"<id>#{location.id}</id>" +
						extra_optional +
					"</location>"
			}

			xml_string = xml_string + "</locations>"

			puts xml_string			
		end
		private :export_location_xml
		
		def export_school_xml(request, schools)
			request.reply.headers['X-info-messages-off'] = true
			request.reply.headers['Content-Type'] = MimeType::XMLText

			xml_string = "<?xml version = \"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?>" + "<schools>"

			schools.each { |school| 
				extra_optional = school.extra ? "<extra>#{school.extra}</extra>" : ""
				xml_string = xml_string + 
					"<school>" +
						"<name>#{school.name}</name>" + 
						"<id>#{school.school_id}</id>" +
						extra_optional +
					"</school>"
			}

			xml_string = xml_string + "</schools>"

			puts xml_string			
		end
		private :export_school_xml		
	end
end
