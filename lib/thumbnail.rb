lib_want :FileServing, "type"

require 'RMagick'
require 'open-uri'

if (site_module_loaded? :FileServing)
	class Thumbnail < FileServing::Type
		register "ext_thumbnail"
		immutable
		
		def initialize(typeid, primaryid, secondaryid, thumbnail_method_and_extension)
			@klass = TypeID.get_class(typeid.to_i)
			@object = @klass.find(:first, primaryid.to_i, secondaryid.to_i) if !@klass.nil?
			
			thumbnail_method_name = thumbnail_method_and_extension.split(".")[0]
			@thumbnail_source_method = "#{thumbnail_method_name}_source".to_sym
			
			if(!@object.respond_to? @thumbnail_source_method)
				raise PageError.new(404), "Invalid thumbnail request!"
			end

			super(typeid, primaryid, secondaryid, thumbnail_method_and_extension)
		end
		
		def not_found(out)
			href = @object.send(@thumbnail_source_method)
			
			begin
				uri = URI.parse(href.gsub(/(http:\/\/)+/,"http://"))
				str = uri.read
			
				images = Magick::Image.from_blob str
				img = images[0]
				thumb = img.crop_resized(78, 78)
				thumb.write out.path
			rescue
				@object.clear_thumbnail_refs
				raise FileServing::NotFoundError.new("Error creating thumbnail: #{href}", $!)
			end
		end
	end
end
