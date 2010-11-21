lib_require :Core, 'data_structures/enum_map'

class Module
	# define name and name= to wrap around an Enum type.
	# if a symbol is invalid it will raise an error on the assignment.
	def enum_map_attr(column, hash, default = hash.keys.first)
		variable_name = column.sym_ivar_name

		self.send(:define_method, column.sym_name) {
			if (instance_variable_defined?(variable_name))
				return instance_variable_get(variable_name).symbol;
			else
				instance_variable_set(variable_name, EnumMap.new(default, hash));
				return instance_variable_get(variable_name).symbol;
			end
		}

		self.send(:define_method, column.sym_name_ex) {
			if (instance_variable_defined?(variable_name))
				return instance_variable_get(variable_name);
			else
				instance_variable_set(variable_name, EnumMap.new(default, hash));
				return instance_variable_get(variable_name);
			end
		}

		self.send(:define_method, column.sym_name_eq) { |symbol|
			if (instance_variable_defined?(variable_name))
				instance_variable_get(variable_name).symbol = symbol;
			else
				instance_variable_set(variable_name, EnumMap.new(symbol, hash));
			end
		}
	end
end
