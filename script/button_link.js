Overlord.assign({
	minion: "button_link",
	click: function(event, element) {
		path = element.getAttribute("path");
		if (path) {
			YAHOO.util.Event.preventDefault(event);
			document.location = path;
		}
	}
});

Overlord.assign({
	minion: "button",
	mousedown: function(event, element) {
		YAHOO.util.Dom.addClass(element, "pressed");
	},
	mouseup: function(event, element) {
		YAHOO.util.Dom.removeClass(element, "pressed");
	},
	order: -1
});