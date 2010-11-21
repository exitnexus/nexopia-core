/*
	Provides a central location to subscribe to and post events. A new CustomEvent will be
	made for each eventName passed in. This provides an easy way for objects to communicate
	while not being tightly coupled. The listening object does not have to have any sort of
	reference to the firing object. It simply subscribes to events of a certain name and is
	responsible for determining whether or not it should respond to an event of that name
	when it is fired.
	
	Suggested use case:
	-------------------
	
	// In the listening object:
	
	function callback(event, args)
	{
		var paramHash = args[0];
		if(condition) // condition: the object wants to respond to the notification, based on the paramHash
		{
			// Do stuff...
		}
	};
	
	NotificationCenter.defaultNotificationCenter.subscribe("someEvent", {param1:value1, param2:value2});

	// In the notifying object:
	
	NotificationCenter.defaultNotificationCenter.fire("someEvent", {param1:value1, param2:value2});
*/
function NotificationCenter(theScope)
{
	this.events = {};
	this.notificationScope = theScope;
};

NotificationCenter.prototype = 
{
	subscribe: function(eventName, eventHandler)
	{	
		var e = this.eventForName(eventName);
		if(e)
		{
			e.subscribe(eventHandler, this.notificationScope);
		}
	},
	
	fire: function(eventName, eventInfoHash)
	{
		var e = this.eventForName(eventName);
		if(e) 
		{ 
			e.fire(eventInfoHash);
		}
	},
	
	unsubscribe: function(eventName, eventHandler)
	{
		var e = this.eventForName(eventName);
		if(e) 
		{ 
			e.unsubscribe(eventHandler, this.notificationScope);
		}
	},
	
	eventForName: function(eventName)
	{
		var e = this.events[eventName];
		if(!e)
		{
			e = new YAHOO.util.CustomEvent(eventName, this);
			this.events[eventName] = e;
		}
		
		return e;
	}
};

NotificationCenter.defaultNotificationCenter = new NotificationCenter(null);