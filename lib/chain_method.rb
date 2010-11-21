module Kernel
	#the result of the block for the prechain method should be the parameter to be passed on to the original method
	#WARNING: this only works properly with single parameter methods at the moment
	def prechain_method(method_name, &block)
		counter = 0
		old_method_name = :"_prechain_#{method_name.to_s}_#{counter}"
		while (self.method_defined?(old_method_name))
			counter += 1
			old_method_name = :"_prechain_#{method_name.to_s}_#{counter}"
		end
		alias_method old_method_name, method_name.to_sym
		self.send(:define_method, method_name.to_sym) { |*args|
			result = instance_exec(*args, &block)
			self.send(old_method_name, result)
		}
	end
	
	def postchain_method(method_name, &block)
		counter = 0
		old_method_name = :"_postchain_#{method_name.to_s}_#{counter}"
		while (self.method_defined?(old_method_name))
			counter += 1
			old_method_name = :"_postchain_#{method_name.to_s}_#{counter}"
		end
		alias_method old_method_name, method_name.to_sym
		self.send(:define_method, method_name.to_sym) { |*args|
			args << self.send(old_method_name, *args)
			instance_exec(*args, &block)
		}
	end
end