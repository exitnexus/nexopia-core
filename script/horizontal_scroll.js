/*
	Caution: use only when absolutely necessary. Great evil lies here. See NEX-2491.
*/
HorizontalScrollContent = 
{
	paddingAdjustment: 26,
	
	setupResize: function(element)
	{
		YAHOO.util.Event.addListener(window, "resize", this.resizeToAvailableWidth, element, this);
		this.resizeToAvailableWidth(null, element);
	},
	
	resizeToAvailableWidth: function(event, element)
	{
		if(!this.sidebarWidth)
		{
			var sidebar = document.getElementById('sidebar');
			this.sidebarWidth = sidebar.offsetWidth;
		}
				
		var browserWidth = YAHOO.util.Dom.getViewportWidth();
		var maxContentWidth = browserWidth - (this.sidebarWidth + HorizontalScrollContent.paddingAdjustment);
		YAHOO.util.Dom.setStyle(element, 'width', maxContentWidth + 'px');
	}
};

Overlord.assign({
	minion: "horizontal_scrolling_expand_to_sidebar",
	load: HorizontalScrollContent.setupResize,
	scope: HorizontalScrollContent
});