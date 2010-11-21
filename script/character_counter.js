//require script_manager.js

function CharacterCounter(textField, remaining)
{
	textField.characterCounter = this;
	
	this.displayElement = YAHOO.util.Dom.get(textField.id + "_character_counter");
	if(!this.displayElement)
	{
		var brElement = document.createElement("br");
		var lengthText = document.createElement("span");
		lengthText.innerHTML = "Length: ";
		this.displayElement = document.createElement("span");
		this.displayElement.id = textField.id + "_character_counter";

		textField.parentNode.insertBefore(brElement, textField.nextSibling);
		textField.parentNode.insertBefore(lengthText, brElement.nextSibling);
		textField.parentNode.insertBefore(this.displayElement, this.displayElement.nextSibling);
	}
	
	this.textField = textField;
	this.maxLimit = parseInt(textField.getAttribute("maxlength"), 10);
	this.remaining = (remaining == true);
	
	YAHOO.util.Event.addListener(this.textField, "change", this.update, this, true);
	YAHOO.util.Event.addListener(this.textField, "keydown", this.update, this, true);
	YAHOO.util.Event.addListener(this.textField, "keyup", this.update, this, true);

	this.update();
}


CharacterCounter.prototype = {
	update: function()
	{
		if(this.textField.value.length > this.maxLimit)
		{
			this.textField.value = this.textField.value.substring(0, this.maxLimit);
		}
		
		if(this.remaining)
		{
			this.displayElement.innerHTML = parseInt(this.maxLimit) - parseInt(this.textField.value.length);
		}
		else
		{
			this.displayElement.innerHTML = this.textField.value.length + " / " + this.maxLimit;
		}
	}
};


Overlord.assign({
	minion: "show_character_count",
	load: function(element)
	{
		new CharacterCounter(element);
	},
	sope:this
});


Overlord.assign({
	minion: "show_character_count:remaining",
	load: function(element)
	{
		new CharacterCounter(element, true);
	},
	scope:this
});