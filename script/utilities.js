//require nexopia.js
Nexopia.Utilities = {
	/*
		@img: id or element of the image to base actions on
		@options: {
			load: function that gets called when the img is ready (either immediately or after load)
			scope: scope the function gets called in, defaults to the image
			args: an array containing arguments to be passed to the function, defaults to [the image]
		}
	*/
	withImage: function(img, options) {
		var imgElement = YAHOO.util.Dom.get(img);
		if (!options.scope) {
			options.scope = imgElement;
		}
		if (!options.args) {
			options.args = [imgElement];
		}
		if (imgElement.complete) {
			options.load.apply(options.scope, options.args);
		} else {
			YAHOO.util.Event.on(imgElement, 'load', function() {options.load.apply(options.scope, options.args);});
		}
	},
	//withCanvas is useful for IE canvas initialization issues, it polls until the canvases have been setup by excanvas.js properly.
	withCanvas: function(canvas, options) {
		canvas = YAHOO.util.Dom.get(canvas);
		if (!options.scope) {
			options.scope = canvas;
		}
		if (!options.args) {
			options.args = [canvas];
		}
		if (!canvas.getContext) {
			YAHOO.lang.later(10, this, this.withCanvas, [canvas,options], false);
		} else {
			options.load.apply(options.scope, options.args);
		}
	},
	escapeHTML: function(string) {
		s = string.replace(/&nbsp;/g,' ').replace(/&/g,'&amp;').replace(/>/g,'&gt;').replace(/</g,'&lt;').replace(/"/g,'&quot;').replace(/&amp;hearts;/, '&hearts;');
		for (var i = 0; i <= 32; i++){
			s = s.replace('&#' + i + ';', "");
		}
		return s;
	},
	escapeURI: function(string) {
		return(escape(string).replace(/\+/g, '%2B'));
	},
	getHexValue: function(color)
	{
		rgb = color.replace(/rgb\((.*?),\s*(.*?),\s*(.*?)\s*\)/,'$1,$2,$3').split(',');
		return Nexopia.Utilities.getHex(rgb);
	},
	getHex: function(rgb)
	{
		return Nexopia.Utilities.toHex(rgb[0]) + Nexopia.Utilities.toHex(rgb[1]) + Nexopia.Utilities.toHex(rgb[2]);
	},
	toHex: function(n) 
	{
		if (n==null) {
			return "00";
		}
		n=parseInt(n, 10); 
		if (n==0 || isNaN(n)) {
			return "00";
		}
		n=Math.max(0,n); 
		n=Math.min(n,255); 
		n=Math.round(n);

		return "0123456789ABCDEF".charAt((n-n%16)/16) + "0123456789ABCDEF".charAt(n%16);
	},
	deduceImgColor: function(element)
	{
		var img = document.createElement("img");
		img.className = "color_icon";
		element.appendChild(img);
		var color = YAHOO.util.Dom.getStyle(img, 'color');
		element.removeChild(img);
		return color;
	},
	trim: function(str) {
		return str.replace(/^\s+|\s+$/g, '') ;
	},
	concatForm: function(baseForm, formToConcat) {
		// Normally we could just do formToConcat.elements, but IE fails miserably when forms are nested
		// and can't figure out the correct children, so we need to use a slightly less elegant appraoch
		// to getting our elements.
		var children = YAHOO.util.Dom.getElementsBy(
			function(e) { 
				return (
					e.tagName.toLowerCase() == 'input' ||
					e.tagName.toLowerCase() == 'select' ||
					e.tagName.toLowerCase() == 'textarea' ||
					e.tagName.toLowerCase() == 'button');
			}, null, formToConcat);
			
		for(var i = 0; i < children.length; i++)
		{
			if(children[i].name != null && children[i].name != "" && children[i].value != undefined)
			{
				// Aha! Normal form posting doesn't even pass along a checkbox that isn't checked, so
				// if we don't even want to create a form element if our source form has an unchecked
				// checkbox. Doing so would confuse the actual post of the concatenated form.
				if(	children[i].tagName.toLowerCase() == "input" && 
					(children[i].type == "checkbox" || children[i].type == "radio") && 
					!children[i].checked)
				{
					continue;
				}
				
				var input = document.createElement("input");
				input.type = "hidden";
				input.name = children[i].name;
				input.value = children[i].value;
				baseForm.appendChild(input);
			}
		}		
	},
	setCaretPosition: function(textarea, position)
	{
		if(textarea.setSelectionRange)
		{
			textarea.focus();
			textarea.setSelectionRange(position,position);
		}
		else if(textarea.createTextRange)
		{
			var range = textarea.createTextRange();
			range.collapse(true);
			range.moveEnd('character', position);
			range.moveStart('character', position);
			range.select();
		}
	},
	insertAfter: function(before, after) {
		if (before.nextSibling) {
			before.parentNode.insertBefore(after,before.nextSibling);
		} else {
			before.parentNode.appendChild(after);
		}
	},
	//getX and getY have been happily stolen from "Javascript: The Definitive Guide" by David Flanagan (5th edition)
	getX: function(element) {
		var x = 0;
		while (element) {
			x += element.offsetLeft;
			element = element.offsetParent;
		}
		return x;
	},
	getY: function(element) {
		var y = 0;
		while (element) {
			y += element.offsetTop;
			element = element.offsetParent;
		}
		return y;
	},
	//more happy theft from http://stackoverflow.com/questions/871399/cross-browser-method-for-detecting-the-scrolltop-of-the-browser-window
	//courtesy of kennebec
	getScrollTop: function() {
		if(typeof pageYOffset!= 'undefined'){
			//most browsers
			return pageYOffset;
		}
		else{
			var B= document.body; //IE 'quirks'
			var D= document.documentElement; //IE with doctype
			D= (D.clientHeight)? D: B;
			return D.scrollTop;
		}
	},
	getScrollLeft: function() {
		if(typeof pageXOffset!= 'undefined'){
			//most browsers
			return pageXOffset;
		}
		else{
			var B= document.body; //IE 'quirks'
			var D= document.documentElement; //IE with doctype
			D= (D.clientWidth)? D: B;
			return D.scrollLeft;
		}
	},
	//pilfered from http://snipplr.com/view/2638/height-of-window/ courtesy of Rob Zand
	getWindowHeight: function() {
		return window.innerHeight ? window.innerHeight : document.documentElement.clientHeight ? document.documentElement.clientHeight : document.body.clientHeight;
	},
	getWindowWidth: function() {
		return window.innerWidth ? window.innerWidth : document.documentElement.clientWidth ? document.documentElement.clientWidth : document.body.clientWidth;
	},
	stringToRGB: function(color_string) {
		return (new this.ColorConverter(color_string)).toRGB();
	},
	stringToHex: function(color_string) {
		return (new this.ColorConverter(color_string)).toHex();
	},
	ColorConverter: function(color_string) {
		this.ok = false;

		// strip any leading #
		if (color_string.charAt(0) == '#') { // remove # if any
			color_string = color_string.substr(1,6);
		}

		color_string = color_string.replace(/ /g,'');
		color_string = color_string.toLowerCase();

		// before getting into regexps, try simple matches
		// and overwrite the input
		var simple_colors = {
			aliceblue: 'f0f8ff',
			antiquewhite: 'faebd7',
			aqua: '00ffff',
			aquamarine: '7fffd4',
			azure: 'f0ffff',
			beige: 'f5f5dc',
			bisque: 'ffe4c4',
			black: '000000',
			blanchedalmond: 'ffebcd',
			blue: '0000ff',
			blueviolet: '8a2be2',
			brown: 'a52a2a',
			burlywood: 'deb887',
			cadetblue: '5f9ea0',
			chartreuse: '7fff00',
			chocolate: 'd2691e',
			coral: 'ff7f50',
			cornflowerblue: '6495ed',
			cornsilk: 'fff8dc',
			crimson: 'dc143c',
			cyan: '00ffff',
			darkblue: '00008b',
			darkcyan: '008b8b',
			darkgoldenrod: 'b8860b',
			darkgray: 'a9a9a9',
			darkgreen: '006400',
			darkkhaki: 'bdb76b',
			darkmagenta: '8b008b',
			darkolivegreen: '556b2f',
			darkorange: 'ff8c00',
			darkorchid: '9932cc',
			darkred: '8b0000',
			darksalmon: 'e9967a',
			darkseagreen: '8fbc8f',
			darkslateblue: '483d8b',
			darkslategray: '2f4f4f',
			darkturquoise: '00ced1',
			darkviolet: '9400d3',
			deeppink: 'ff1493',
			deepskyblue: '00bfff',
			dimgray: '696969',
			dodgerblue: '1e90ff',
			feldspar: 'd19275',
			firebrick: 'b22222',
			floralwhite: 'fffaf0',
			forestgreen: '228b22',
			fuchsia: 'ff00ff',
			gainsboro: 'dcdcdc',
			ghostwhite: 'f8f8ff',
			gold: 'ffd700',
			goldenrod: 'daa520',
			gray: '808080',
			green: '008000',
			greenyellow: 'adff2f',
			honeydew: 'f0fff0',
			hotpink: 'ff69b4',
			indianred : 'cd5c5c',
			indigo : '4b0082',
			ivory: 'fffff0',
			khaki: 'f0e68c',
			lavender: 'e6e6fa',
			lavenderblush: 'fff0f5',
			lawngreen: '7cfc00',
			lemonchiffon: 'fffacd',
			lightblue: 'add8e6',
			lightcoral: 'f08080',
			lightcyan: 'e0ffff',
			lightgoldenrodyellow: 'fafad2',
			lightgrey: 'd3d3d3',
			lightgreen: '90ee90',
			lightpink: 'ffb6c1',
			lightsalmon: 'ffa07a',
			lightseagreen: '20b2aa',
			lightskyblue: '87cefa',
			lightslateblue: '8470ff',
			lightslategray: '778899',
			lightsteelblue: 'b0c4de',
			lightyellow: 'ffffe0',
			lime: '00ff00',
			limegreen: '32cd32',
			linen: 'faf0e6',
			magenta: 'ff00ff',
			maroon: '800000',
			mediumaquamarine: '66cdaa',
			mediumblue: '0000cd',
			mediumorchid: 'ba55d3',
			mediumpurple: '9370d8',
			mediumseagreen: '3cb371',
			mediumslateblue: '7b68ee',
			mediumspringgreen: '00fa9a',
			mediumturquoise: '48d1cc',
			mediumvioletred: 'c71585',
			midnightblue: '191970',
			mintcream: 'f5fffa',
			mistyrose: 'ffe4e1',
			moccasin: 'ffe4b5',
			navajowhite: 'ffdead',
			navy: '000080',
			oldlace: 'fdf5e6',
			olive: '808000',
			olivedrab: '6b8e23',
			orange: 'ffa500',
			orangered: 'ff4500',
			orchid: 'da70d6',
			palegoldenrod: 'eee8aa',
			palegreen: '98fb98',
			paleturquoise: 'afeeee',
			palevioletred: 'd87093',
			papayawhip: 'ffefd5',
			peachpuff: 'ffdab9',
			peru: 'cd853f',
			pink: 'ffc0cb',
			plum: 'dda0dd',
			powderblue: 'b0e0e6',
			purple: '800080',
			red: 'ff0000',
			rosybrown: 'bc8f8f',
			royalblue: '4169e1',
			saddlebrown: '8b4513',
			salmon: 'fa8072',
			sandybrown: 'f4a460',
			seagreen: '2e8b57',
			seashell: 'fff5ee',
			sienna: 'a0522d',
			silver: 'c0c0c0',
			skyblue: '87ceeb',
			slateblue: '6a5acd',
			slategray: '708090',
			snow: 'fffafa',
			springgreen: '00ff7f',
			steelblue: '4682b4',
			tan: 'd2b48c',
			teal: '008080',
			thistle: 'd8bfd8',
			tomato: 'ff6347',
			turquoise: '40e0d0',
			violet: 'ee82ee',
			violetred: 'd02090',
			wheat: 'f5deb3',
			white: 'ffffff',
			whitesmoke: 'f5f5f5',
			yellow: 'ffff00',
			yellowgreen: '9acd32'
		};
		for (var key in simple_colors) {
			if (color_string == key) {
				color_string = simple_colors[key];
			}
		}
		// emd of simple type-in colors

		// array of color definition objects
		var color_defs = [
		{
			re: /^rgb\((\d{1,3}),\s*(\d{1,3}),\s*(\d{1,3})\)$/,
			example: ['rgb(123, 234, 45)', 'rgb(255,234,245)'],
			process: function (bits){
				return [
				parseInt(bits[1]),
				parseInt(bits[2]),
				parseInt(bits[3])
				];
			}
		},
		{
			re: /^([\da-fA-F]{2})([\da-fA-F]{2})([\da-fA-F]{2})$/,
			example: ['#00ff00', '336699'],
			process: function (bits){
				return [
				parseInt(bits[1], 16),
				parseInt(bits[2], 16),
				parseInt(bits[3], 16)
				];
			}
		},
		{
			re: /^([\da-fA-F]{1})([\da-fA-F]{1})([\da-fA-F]{1})$/,
			example: ['#fb0', 'f0f'],
			process: function (bits){
				return [
				parseInt(bits[1] + bits[1], 16),
				parseInt(bits[2] + bits[2], 16),
				parseInt(bits[3] + bits[3], 16)
				];
			}
		}
		];

		// search through the definitions to find a match
		for (var i = 0; i < color_defs.length; i++) {
			var re = color_defs[i].re;
			var processor = color_defs[i].process;
			var bits = re.exec(color_string);
			if (bits) {
				channels = processor(bits);
				this.r = channels[0];
				this.g = channels[1];
				this.b = channels[2];
				this.ok = true;
			}

		}

		// validate/cleanup values
		this.r = (this.r < 0 || isNaN(this.r)) ? 0 : ((this.r > 255) ? 255 : this.r);
		this.g = (this.g < 0 || isNaN(this.g)) ? 0 : ((this.g > 255) ? 255 : this.g);
		this.b = (this.b < 0 || isNaN(this.b)) ? 0 : ((this.b > 255) ? 255 : this.b);

		// some getters
		this.toRGB = function () {
			return [this.r,this.g,this.b];
		}
		this.toHex = function () {
			var r = this.r.toString(16);
			var g = this.g.toString(16);
			var b = this.b.toString(16);
			if (r.length == 1) r = '0' + r;
			if (g.length == 1) g = '0' + g;
			if (b.length == 1) b = '0' + b;
			return '#' + r + g + b;
		}
	}
};