lib_require :Core, 'storable/storable'

class EmailOptout < Storable
	init_storable(:db, "email_optout")
end