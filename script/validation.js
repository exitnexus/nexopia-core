Validation = {
	/*
		fields: Optional. If these are passed in, we'll initialize Validation.states with "none" for
	 			each so that when Validation.allStatesAreValid() is called, it will return false by
				default, even if the user hasn't clicked inside any of the fields.
	*/
	init: function(fields)
	{
		for(var i = 0; i < fields.length; i++)
		{
			Validation.states[fields[i]] = "none";
		}
	},
	
	// silent: optional - only update the Validation.states entry
	displayValidation: function(field_id, state, message, silent)
	{
		Validation.states[field_id] = state;
	
		if(silent != null && silent == true)	
		{
			return;
		}
		
		array_regexp = /(.*)\[(.*)\]/;
		field_index = "";
		if (field_id.match(array_regexp))
		{
			field_name = field_id.replace(array_regexp, "$1");
			index = field_id.replace(array_regexp, "$2");
			
			field_id = field_name;
			field_index = "[" + index + "]";
		}
		
		error_icon = document.getElementById(field_id + "_error_icon" + field_index);
		valid_icon = document.getElementById(field_id + "_valid_icon" + field_index);
		warning_icon = document.getElementById(field_id + "_warning_icon" + field_index);

		var active_icon = null;
		
		if (state == "error")
		{
			if (warning_icon) warning_icon.style.display = "none";
			if (error_icon) error_icon.style.display = "block";
			if (valid_icon) valid_icon.style.display = "none";
			
			active_icon = error_icon;
		}
		else if (state == "valid")
		{
			if (warning_icon) warning_icon.style.display = "none";
			if (error_icon) error_icon.style.display = "none";
			if (valid_icon) valid_icon.style.display = "block";
			
			active_icon = valid_icon;
		}
		else if (state == "warning")
		{
			if (warning_icon) warning_icon.style.display = "block";
			if (error_icon) error_icon.style.display = "none";
			if (valid_icon) valid_icon.style.display = "none";
			
			active_icon = warning_icon;
		}
		else
		{
			if (warning_icon) warning_icon.style.display = "none";
			if (error_icon) error_icon.style.display = "none";
			if (valid_icon) valid_icon.style.display = "none";
		}
		
		message_div = document.getElementById(field_id + "_vm" + field_index);
		if (message_div != null)
		{
			message_div.className = "validation_" + state + "_text";
			message_div.innerHTML = message;	
		}
		else if (message != "")
		{
			new YAHOO.widget.Tooltip(field_id + "_" + state + "_tooltip" + field_index, 
				{ context: active_icon.id, zIndex: 500, showdelay: 0, hidedelay: 0, text:message } );
		}
				
	},
	
	
	clientValidate: function()
	{
		
	},
	
	
	ajaxValidate: function(field_id, url, silent)
	{
		Validation.displayValidation(field_id, "none", "Checking...", silent);
		
		callback = {
			success: function(o) {
				xmlRoot = o.responseXML.documentElement;
				stateTag = xmlRoot.getElementsByTagName("state")[0];
				messageTag = xmlRoot.getElementsByTagName("message")[0];
				stateText = stateTag.firstChild == null ? "" : stateTag.firstChild.nodeValue;
				messageText = messageTag.firstChild == null ? "" : messageTag.firstChild.nodeValue;
				escapedMessageText = messageText.replace(/</, "&lt;").replace(/>/, "&gt;");
				
				Validation.displayValidation(field_id, stateText, escapedMessageText, silent);
			}
		};
		
		var formKeys = document.getElementsByName("form_key[]");
		var formKeyString = "";
		for(var i = 0; i < formKeys.length; i++)
		{
			formKeyString = formKeyString + "form_key[]=" + formKeys[i].value + "&";
		}
		
		value_field = document.getElementById(field_id);
		value = Nexopia.Utilities.escapeURI(value_field.value);
		
		YAHOO.util.Connect.asyncRequest('POST', url, callback, formKeyString + "&value=" + value);
	},
	
	
	/*
		When Validation.displayValidation() (or Validation.ajaxValidate()) is called for any field, we
		update Validation.states, which reflect the overall validity of the page. This function returns
		true if all of the fields that have been validated (or initialized) are in a valid (or warning)
		state and false if they are not.
		
		It's best to initialize the Validation.states first by passing an array of field names into
		Validation.init().
	*/
	allStatesAreValid: function()
	{
		for(var key in Validation.states)
		{
			var value = Validation.states[key];
			if (!(value == "valid" || value == "warning"))
			{
				return false;
			}
		}
		
		return true;
	}
}
Validation.states = [];


function ValidationResults(state, message)
{
	this.state = state;
	this.message = message;
}

/*
	A ValidationChain represents a collection of ValidationRules that will be checked in the order 
	they were added to the ValidationChain. The first rule that gives a ValidationResults in an
	"error" state will "break" the chain. No further validation will happen, and the ValidationResults
	that will be returned. If the entire ValidationChain contains rules that only resolve to "valid"
	or "warning" state ValidationResults, the ValidationChain will be considered to be "valid" and
	the ValidationResults from the last evaluated rule will be returned.
*/
function ValidationChain()
{
	this.client_chain = new Array();
	this.server_chain = new Array();
	this.none_override = null;
	this.valid_override = null;
}
ValidationChain.prototype =
{
	add: function(rule)
	{
		if (rule.isServerSide())
		{
			this.server_chain[this.server_chain.length] = rule;
		}
		else
		{
			this.client_chain[this.client_chain.length] = rule;
		}
	},

	/*
		Sets a rule that will pre-maturely break the Validation::Chain if it returns Validation::Results
		that have a state of :none. This override takes precedence over the valid_override.
	*/
	setNoneOverride: function(rule)
	{
		this.none_override = rule;
	},

	/*
		Sets a rule that will pre-maturely break the Validation::Chain if it returns Validation::Results
		that have a state of :valid. This override is trumped by the none_override.
	*/
	setValidOverride: function(rule)
	{
		this.valid_override = rule;
	},


	/*
		Validates the chain and returns Validation::Results in the following order:
		1. A none_override that has Validation::Results in a :none state.
		2. A valid_override that has Validation::Results in a :valid state.
		3. The Validation::Results of a rule that fails to resolve into a :valid or
			 :warning state.
		4. The Validation::Results of the rule that was last added to the chain.
	*/
	validate: function()
	{
		if (this.none_override != null)
		{
			results = this.none_override.validate();
			if (results.state == "none")
			{
				return results;
			}
		}

		if (this.valid_override != null)
		{
			results = this.valid_override.validate();
			if (results.state == "valid")
			{
				return results;
			}
		}
	
		results = new ValidationResults("valid","");
	
		// Do client-side validation
		for (var i = 0; i < this.client_chain.length; i++)
		{
			rule = this.client_chain[i];
			results = rule.validate();
			if (results.state == "error")
			{
				return results;
			}
		}
/*
		// Do any AJAX validation
		if (this.server_chain.length > 0)
		{
			// TODO: Change to the validation handler in Core!!!
			ruleString = "/account"
			for (var i = 0; i < this.server_chain.length; i++)
			{
				rule = this.server_chain[i];
				className = rule.className.toString();
				ruleString = ruleString + "/" + className;
			}

			alert(ruleString);
			// results = ajaxValidate(rules)
		}
*/
		return results;
	},
		
	ajaxValidate: function()
	{
		
	}
}


function ValidationSet()
{
	this.validation_results = new Array();
}
ValidationSet.prototype =
{
	/*	
		Add the given field and ValidationResults to representing it to the ValidationSet.
		
		field: 		The name/id of the field in the form. See ValidationDisplay for more information on 
					naming conventions.
		results: 	The ValidationResults to associate with the field.
		show_icon_for_valid:
					Can optionally "turn off" the default of showing a valid icon for ValidationResults in
					a "valid" state.
	*/
	add: function(field,results,show_icon_for_valid)
	{
		show_icon_for_valid = show_icon_for_valid || true;
		this.validation_results[field] = results;	
	},


	get_results: function(field)
	{
		return this.validation_results[field];
	},


	// Bind all Validation::Display objects in this Validation::Set to the given Template.
	bind: function(template)
	{
/*		@validation_displays.values.each { |display|
			display.bind(template);
*/
	}
}


function ValidationValueAccessor(field_id, field_value)
{
	this.field_id = field_id;
	this.field_value = field_value;
}
ValidationValueAccessor.prototype =
{
	value: function()
	{
		var field = document.getElementById(this.field_id);

		if (field.type == "checkbox")
		{
			return field.checked;
		}

		return field.value;
	}
};
