require 'spec'
require 'spec/runner/formatter/specdoc_formatter'

module Spec; module Runner; module Formatter
	class SpecdocTimestampedFormatter < SpecdocFormatter
		def example_started(example)
			@timestamp = Time.new.to_f
		end

		def example_passed(example)
			message = "[%8.4f s][%d kB] - #{example.description}" %
				[Time.new.to_f - @timestamp, MemUsage.rss]
			output.puts green(message)
			output.flush
		end

		def example_failed(example, counter, failure)
			message = "[%8.4f s][%d kB] - #{example.description} (FAILED - #{counter})" %
				[Time.new.to_f - @timestamp, MemUsage.rss]
			error_info = "Exception: #{failure.exception.message}:\nBacktrace:\n#{failure.exception.backtrace.join("\n")}"
			output.puts red(message)
			output.puts yellow(error_info)
			output.flush
		end
	end
end; end; end

def load_tests_from_dir(dir_path)
	test_dir = Dir.open(dir_path);
	
	file_list = Array.new();
	
	test_dir.each{|file|
		if(File.directory?(file.to_s()))
			next;
		end

		if(/^spec_.*\.rb$/.match(file))
			file_list.push(dir_path + "/" + file.to_s());
		end
	}
	
	return file_list;
end

def find_tests()
	files = [];
	
	site_modules() {|mod|
		if(File.exists?(mod.tests_path) && File.directory?(mod.tests_path))
			files = files + load_tests_from_dir(mod.tests_path);
		else
			next;
		end	
	};
	
	return files;
end

runfiles = [];
test_files = [];

test_list = ENV['RUBY_TESTS'];

if(!test_list.nil?())
	test_files = test_list.split(",");
end

if (test_files.length < 1)
	runfiles = find_tests(); # do everything if nothing is passed in.
else
	test_files.each{|file|
		possible_file = $site.config.site_base_dir + "/" + file;
		if(File.exists?(possible_file) && File.directory?(possible_file))
			runfiles = runfiles + load_tests_from_dir(possible_file);
		elsif(File.exists?(possible_file))
			runfiles << possible_file;
		end
	}
end

runfiles.each {|file|
	$log.info("Loading #{file}")
	require(file);
}
$log.info("Running tests")

Spec::Runner.options.parse_format "Spec::Runner::Formatter::SpecdocTimestampedFormatter"
Spec::Runner.options.colour = true
Spec::Runner::run

