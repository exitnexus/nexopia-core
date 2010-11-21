lib_require :Core, "data_structures/enum"

class Module
	# define name and name= to wrap around an Enum type.
	# if a symbol is invalid it will raise exception on assignment.
	def enum_attr(column, *syms)
		variable_name = column.sym_ivar_name
		syms.flatten!

		self.send(:define_method, column.sym_name) {
			if (instance_variable_defined?(variable_name))
				return instance_variable_get(variable_name).symbol;
			else
				instance_variable_set(variable_name, Enum.new(syms.first, syms));
				return instance_variable_get(variable_name).symbol;
			end
		}

		self.send(:define_method, column.sym_name_eq) { |symbol|
			if (instance_variable_defined?(variable_name))
				instance_variable_get(variable_name).symbol = symbol;
			else
				instance_variable_set(variable_name, Enum.new(symbol, syms));
			end
		}
	end
end
