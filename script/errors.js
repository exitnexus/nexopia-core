Overlord.assign({
	minion: "errors:submit",
	click: function(event, element) {
		var spinner = new Spinner({ context: [element, "tr"], offset: [-24,2], lazyload: true });
		spinner.on();

		var form = YAHOO.util.Dom.getAncestorByTagName(element, 'form');
		YAHOO.util.Connect.setForm(form);
		YAHOO.util.Connect.asyncRequest('POST', form.action + ":Body", new ResponseHandler({
			success: function(o) { spinner.off(); },
			failure: function(o) { spinner.off(); },
			scope: this
		}), "ajax=true");
		
		YAHOO.util.Event.preventDefault(event);
	}
})