# See date_utils.rb for some helpful methods.
class Constants
	MINUTE_IN_SECONDS = 60
	HOURS_IN_DAY = 24
	DAYS_IN_A_WEEK = 7
	DAYS_IN_A_MONTH = 30
	HOUR_IN_SECONDS = 60 * MINUTE_IN_SECONDS
	DAY_IN_SECONDS = HOUR_IN_SECONDS * HOURS_IN_DAY
	WEEK_IN_SECONDS = DAY_IN_SECONDS * DAYS_IN_A_WEEK
	MONTH_IN_SECONDS = DAY_IN_SECONDS * DAYS_IN_A_MONTH
	YEAR = (DAY_IN_SECONDS * 365.2425).to_i
	YEAR_IN_SECONDS = YEAR
end