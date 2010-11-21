Nexopia = {
	JSONData: {},
	jsonTagData: {},
	json: function(id_or_el) {
		var json = null;
		var el = YAHOO.util.Dom.get(id_or_el);
		if (el) {
			if(el.attributes.json_id)
			{
				json = el.attributes.json_id.value;
			}
		}
		if (json) {
			return this.jsonTagData[json];
		} else {
			return null;
		}
	},
	areaBaseURI: function() {
		var match;
		if (match = document.location.href.match(new RegExp("(" + Site.adminSelfURL + "/.*?)(/|$)"))) {
			return match[1];
		} else if (document.location.href.match(new RegExp(Site.adminURL))) {
			return Site.adminURL;
		} else if (document.location.href.match(new RegExp(Site.selfURL))) {
			return Site.selfURL;
		} else if (match = document.location.href.match(new RegExp("(" + Site.userURL + "/.*?)(/|$)"))) {
			return match[1];
		} else {
			return Site.wwwURL;
		}
	}
};

Array.prototype.unique = function (compareFunction) {
	var r = new Array();
	o:for(var i = 0, n = this.length; i < n; i++)
	{
		for(var x = 0, y = r.length; x < y; x++)
		{
			if(!compareFunction)
			{
				if(r[x]==this[i])
				{
					continue o;
				}
			}
			else
			{
				if(compareFunction(r[x],this[i]))
				{
					continue o;
				}
			}
		}
		r[r.length] = this[i];
	}
	return r;
};

Array.prototype.includes = function(object)
{
	for(var o in this)
	{
		if(this[o] == object)
		{
			return true;
		}
	}
	
	return false;
};