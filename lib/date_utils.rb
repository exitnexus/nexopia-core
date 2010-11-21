# Ruby's date/time handling leaves something to be desired.
# We generally deal with dates and times as integers and store
# the values thusly in mysql.  However, this makes it rather
# difficult to take one value and add a day, for example;
# adding 86400 (Constants::DAY_IN_SECONDS) is not correct
# when dealing with daylight saving time, for example.

require 'date'

# Ruby stores date and time information in the Time object, so
# that's what I mean by 'time' here.
# We do not check for overflow.
module DateUtils
	# Convert a given date value to the beginning of the day for
	# that date.  For example, a date representing 11:32 AM will
	# be converted to time 0 on that day.
	def self.get_start_of_day(time)
		d = Time.at(time.to_i)
		return Time.mktime(d.year, d.month, d.day, 0, 0, 0, 0)
	end
	
	# Add a given number of days to the date.  The number of days
	# can be negative.  This takes Daylight Saving Time changes
	# into account.
	def self.add_days(time, delta = 1)
		d = time_to_datetime(time)
		return datetime_to_time(d + delta.to_i)
	end
	
	# Return an integer value representing the number of days
	# between time1 and time2.  We do this calculation based
	# on the date values, not looking at time.  For example:
	# days_between(2009-04-01 11:00, 2009-04-02 08:00) => 1
	# days_between(2009-04-01 08:00, 2009-04-02 11:00) => 1
	# days_between(2009-04-02 11:00, 2009-04-01 08:00) => -1
	def self.days_between(time1, time2)
		return (time_to_date(time2) - time_to_date(time1)).to_i
	end
	
	def self.time_to_datetime(time)
		t = Time.at(time.to_i)
		return DateTime.civil(t.year, t.month, t.day, t.hour, t.min, t.sec)
	end
	
	def self.time_to_date(time)
		t = Time.at(time.to_i)
		return Date.civil(t.year, t.month, t.day)
	end

	# Convert a DateTime to a Time.
	# Note that this returns a Time value, not an integer.
	def self.datetime_to_time(datetime)
		return Time.mktime(datetime.year, datetime.month, datetime.day,
			datetime.hour, datetime.min, datetime.sec)
	end

	# Convert a Date to a Time.
	# Note that this returns a Time value, +not+ an integer.
	def self.date_to_time(date)
		Time.gm(date.year, date.month, date.day)
	end
	
	# Determine the difference between two dates, in years.
	def self.years_between(start, finish = Time.now.to_i)
		if (start.kind_of?(Date))
			first_date = Time.at(date_to_time(start).to_i)
		else
			first_date = Time.at(start.to_i)
		end
		if (finish.kind_of?(Date))
			last_date = Time.at(date_to_time(finish).to_i)
		else
			last_date = Time.at(finish.to_i)
		end
		retval = last_date.year - first_date.year
		if ((retval > 0) &&
			((last_date.month < first_date.month) ||
			 (last_date.month == first_date.month && last_date.day <= first_date.day)) )
			
			retval -= 1
		end
		return retval
	end
end
