//require nexopia.js
//require script_manager.js
Nexopia.DelayedImage = {
	//load the images for any img tags that have their src's on url attributes and are contained by element
	loadImages: function(element) {
		YAHOO.util.Dom.getElementsBy(function(img) {
			return img.attributes.url; //match any img tag inside of element that has a url attribute
		}, "img", element, this.loadImage);
	},
	loadImage: function(img) {
		if (img.attributes.url) {
			img.src = img.attributes.url.value; //set the src attribute to be the value of the url attribute
			img.removeAttribute('url');
		}
	},
	setDelayedSrc: function(element, src) {
		var attr = document.createAttribute('url');
		attr.value = src;
		element.setAttributeNode(attr);
	},
	scrollImages: [],
	scrollBuffer: 1000, //number of pixels of buffer space to give images when loading them
	registerScrollImage: function(element) {
		if (this.scrollImages.length == 0) {
			YAHOO.util.Event.on(window, 'scroll', this.loadScrollImages, this, true);
		}
		this.scrollImages.push({
			element: element,
			y: Nexopia.Utilities.getY(element)
		});
	},
	initializedScrollEvent: false,
	initializedScrollLoad: false,
	loadScrollImages: function() {
		var notLoaded = [];
		for (var i=0;i<this.scrollImages.length;i++) {
			if (this.scrollImages[i].y < Nexopia.Utilities.getScrollTop() + Nexopia.Utilities.getWindowHeight() + this.scrollBuffer) {
				this.loadImage(this.scrollImages[i].element);
			} else {
				notLoaded.push(this.scrollImages[i]);
			}
		}
		this.scrollImages = notLoaded;
		if (this.scrollImages.length == 0) {
			this.initializedScrollLoad = false;
			YAHOO.util.Event.removeListener(window, 'scroll', this.loadScrollImages);
		}
	},
	initialScrollLoad: function() {
		if (!this.initializedScrollLoad) {
			this.initializedScrollLoad = true;
			this.loadScrollImages();
		}
	}
};

Overlord.assign({
	minion: "user_content_image",
	load: Nexopia.DelayedImage.loadImage
});

Overlord.assign({
	minion: "delayed_image:scroll",
	load: Nexopia.DelayedImage.registerScrollImage,
	scope: Nexopia.DelayedImage
});

Overlord.assign({
	minion: "delayed_image:scroll",
	load: Nexopia.DelayedImage.initialScrollLoad,
	scope: Nexopia.DelayedImage,
	order: 1
});