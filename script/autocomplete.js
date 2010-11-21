/*
	The element provided should be followed by these sibling classes:
	
	matches: A div that will hold the query results and allow the user to select one.
	location_id: A hidden field that will hold the id of the location. Defaults to 0.
	query_sublocations: A hidden field that will hold a true/false value indicating whether the location has sublocations
	location_type: A hidden field indicating the type of location to look up.
		- If empty: the query will be done on all locations
		- If "C": the query will be done on cities
		- If "S": the query will be done on states/provinces
		- If "N": the query will be done on countries (nations)
	location_name_default: A hidden field containing the default value for a location field (when there's no location selected)
*/
function LocationAutocomplete(element)
{
	this.locationNameField = element;
	this.locationMatchDiv = YAHOO.util.Dom.getNextSiblingBy(element, function(el){ return YAHOO.util.Dom.hasClass(el, 'matches'); });
	this.locationIDField = YAHOO.util.Dom.getNextSiblingBy(element, function(el){ return YAHOO.util.Dom.hasClass(el, 'location_id'); });
	this.locationQuerySubLocationsField = YAHOO.util.Dom.getNextSiblingBy(element, function(el){ return YAHOO.util.Dom.hasClass(el, 'query_sublocations'); });
	this.locationTypeField = YAHOO.util.Dom.getNextSiblingBy(element, function(el){ return YAHOO.util.Dom.hasClass(el, 'location_type'); });
	this.locationNameDefaultField = YAHOO.util.Dom.getNextSiblingBy(element, function(el){ return YAHOO.util.Dom.hasClass(el, 'location_name_default'); });
	this.locationNameDefault = this.locationNameDefaultField.value;
			
	this.initialize();
}

LocationAutocomplete.prototype = {
	initialize: function()
	{		
		if(this.locationTypeField.value && this.locationTypeField.value != "")
		{
			this.locationQuery = "/core/query/location/" + this.locationTypeField.value
		}
		else
		{
			this.locationQuery = "/core/query/location"
		}
		
	    // DataSource setup
	    this.locationDataSource = new YAHOO.widget.DS_XHR(this.locationQuery,
	        ["location", "name", "id", "extra", "query_sublocations"]);
	    this.locationDataSource.scriptQueryParam = "name";
	    this.locationDataSource.responseType = YAHOO.widget.DS_XHR.TYPE_XML;
	    this.locationDataSource.maxCacheEntries = 60;
		// this.locationDataSource.queryMatchSubset = true;

		this.locationDataSource.connXhrMode = "cancelStaleRequests";

	    // Instantiate AutoComplete
	    this.locationAutoLookup = new YAHOO.widget.AutoComplete(this.locationNameField.id, this.locationMatchDiv.id, this.locationDataSource);
	    
		// AutoComplete configuration
		this.locationAutoLookup.autoHighlight = true;
		// this.locationAutoLookup.typeAhead = true;
		this.locationAutoLookup.minQueryLength = 1;
		this.locationAutoLookup.queryDelay = 0;
		this.locationAutoLookup.forceSelection = true;
		this.locationAutoLookup.maxResultsDisplayed = 10;
	
		// Fix silly IE6 bug
		if (YAHOO.env.ua.ie > 5 && YAHOO.env.ua.ie <= 7)
		{
			this.locationAutoLookup.useIFrame = true;
		}
		
		var itemSelectHandler = function(eventType, args, obj) {
			var selectedElement = args[2];
			
			var name = selectedElement[0];
			var id = selectedElement[1];
			var extra = selectedElement[2];
			var subLocations = selectedElement[3];
			
			obj.locationIDField.value = id;
			obj.locationQuerySubLocationsField.value = subLocations;
		};
		this.locationAutoLookup.itemSelectEvent.subscribe(itemSelectHandler, this);
	
		var forceSelectionClearHandler = function(eventType, args, obj)
		{
			obj.locationIDField.value = 0;
			obj.locationQuerySubLocationsField.value = "true";
			obj.locationNameField.value = obj.locationNameDefault;
			YAHOO.util.Dom.addClass(obj.locationNameField, "default");
		};
		this.locationAutoLookup.selectionEnforceEvent.subscribe(forceSelectionClearHandler, this);
	
		// HTML display of results
		this.locationAutoLookup.formatResult = function(result, sQuery) {
			// This was defined by the schema array of the data source
			var name = result[0];
			var id = result[1];
			var extra = result[2];
			
			var extraInfo = "";
			if (extra != undefined && extra != "")
				extraInfo = "<br/>" + "<span style='font-size: 10px; color: grey'>" + " ("+ extra + ")" + "</span>";
			
			return name + extraInfo;
		};
		
		var self = this;
		YAHOO.util.Event.addListener(this.locationNameField, "focus", function() {
			if(self.locationNameField.value == self.locationNameDefault)
			{
				self.locationNameField.value = "";
				YAHOO.util.Dom.removeClass(self.locationNameField, "default");
			}
		});		
	}	
};

Overlord.assign({
	minion: "location_autocomplete",
	load: function(element) {
		new LocationAutocomplete(element);
	}
});

/*
	The element provided should be followed by these sibling classes:

	matches: A div that will hold the query results and allow the user to select one.
	school_id: A hidden field that will hold the id of the school. Defaults to 0.
	school_name_default: A hidden field containing the default value for a school field (when there's no school selected)
*/
function SchoolAutocomplete(element)
{
	this.schoolNameField = element;
	this.schoolMatchDiv = YAHOO.util.Dom.getNextSiblingBy(element, function(el){ return YAHOO.util.Dom.hasClass(el, 'matches'); });
	this.schoolIDField = YAHOO.util.Dom.getNextSiblingBy(element, function(el){ return YAHOO.util.Dom.hasClass(el, 'school_id'); });
	this.schoolNameDefaultField = YAHOO.util.Dom.getNextSiblingBy(element, function(el){ return YAHOO.util.Dom.hasClass(el, 'school_name_default'); });
	this.schoolNameDefault = this.schoolNameDefaultField.value;
	
	this.initialize();
}

SchoolAutocomplete.prototype = {
	initialize: function()
	{
	    // DataSource setup
	    this.schoolDataSource = new YAHOO.widget.DS_XHR("/core/query/school",
	        ["school", "name", "id", "extra"]);
	    this.schoolDataSource.scriptQueryParam = "name";
	    this.schoolDataSource.responseType = YAHOO.widget.DS_XHR.TYPE_XML;
	    this.schoolDataSource.maxCacheEntries = 60;

		this.schoolDataSource.connXhrMode = "cancelStaleRequests";

	    // Instantiate AutoComplete
	    this.schoolAutoLookup = new YAHOO.widget.AutoComplete(this.schoolNameField.id, this.schoolMatchDiv.id, this.schoolDataSource);
	    
		// AutoComplete configuration
		this.schoolAutoLookup.autoHighlight = true;

		this.schoolAutoLookup.minQueryLength = 1;
		this.schoolAutoLookup.queryDelay = 0.2;
		this.schoolAutoLookup.forceSelection = true;
		this.schoolAutoLookup.maxResultsDisplayed = 10;
	
		// Fix silly IE6 bug
		if (YAHOO.env.ua.ie > 5 && YAHOO.env.ua.ie <= 7)
		{
			this.schoolAutoLookup.useIFrame = true;
		}
		
		var itemSelectHandler = function(eventType, args, obj) {
			var selectedElement = args[2];
			
			var name = selectedElement[0];
			var id = selectedElement[1];
			var extra = selectedElement[2];
			
			obj.schoolIDField.value = id;
		};
		this.schoolAutoLookup.itemSelectEvent.subscribe(itemSelectHandler, this);
	
		var forceSelectionClearHandler = function(eventType, args, obj)
		{
			obj.schoolIDField.value = 0;
			obj.schoolNameField.value = obj.schoolNameDefault;
			YAHOO.util.Dom.addClass(obj.schoolNameField, "default");
		};
		this.schoolAutoLookup.selectionEnforceEvent.subscribe(forceSelectionClearHandler, this);
	
		// HTML display of results
		this.schoolAutoLookup.formatResult = function(result, sQuery) {
			// This was defined by the schema array of the data source
			var name = result[0];
			var id = result[1];
			var extra = result[2];
			
			var extraInfo = "";
			if (extra != undefined && extra != "")
				extraInfo = "<br/>" + "<span style='font-size: 10px; color: grey'>" + " ("+ extra + ")" + "</span>";
			
			return name + extraInfo;
		};
		
		var self = this;
		YAHOO.util.Event.addListener(this.schoolNameField, "focus", function() {
			if(self.schoolNameField.value == self.schoolNameDefault)
			{
				self.schoolNameField.value = "";
				YAHOO.util.Dom.removeClass(self.schoolNameField, "default");
			}
		});
	}	
};

Overlord.assign({
	minion: "school_autocomplete",
	load: function(element) {
		new SchoolAutocomplete(element);
	}
});