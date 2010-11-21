class Utilities
	class << self
		def extract_options!(args)
			options = {};
			delete_elements = [];
			args.each {|arg|
				if (arg.is_a?(Symbol))
					options[arg] = true;
					delete_elements << arg;
				elsif (arg.is_a?(Hash))
					options.merge!(arg);
					delete_elements << arg;
				end
			}
			delete_elements.each {|element|
				args.delete(element);
			}
			return options
		end
	end
end