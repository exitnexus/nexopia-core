Overlord = {
	jobs: {
		all: [], //list of all the jobs we need taken care of
		load: [], //list of jobs to be initialized for the window.onload event
		dom: [], //list of jobs to be initialized at the onDOMReady event
		available: [] //list of jobs to be initialized immediately after their elements are on the page
	},
	assign: function(job) {
		//you can pass in either just a raw object that would be the constructor argument to Overlord.Job
		//or an Overlord.Job object
		if (!this.Job.prototype.isPrototypeOf(job)) {
			job = new this.Job(job);
		}
		this.jobs.all.push(job);
		this.jobs[job.init].push(job);
	},
	minionAvailable: function(id) {
		this.summonMinions(YAHOO.util.Dom.get(id), 'available');
	},
	summonMinions: function(root, init) {
		
		start_begin = (new Date()).getTime();
		init = init || 'all';
		if (init) {
			
			var minionsList = [];
			//find the minion elements we care about and sort them by name
			if (init != 'available') {
				//Since we need to get the same list for both the load and the dom steps lets cache the first one
				//to complete and use it for the other saving ourselves a full dom scan.
				if (!root && this.fullMinionsList) {
					minionsList = this.fullMinionsList;
				} else {
					minionsList = this.findMinions(root);
					this.fullMinionsList = minionsList;
				}
			} else {
				minionsList = [root];
			}
			
			var minions = {};
			for (var i=0; i<minionsList.length; i++) {
				var minion = minionsList[i];
				var names = minion.getAttribute('minion_name');
				names = names.split(' ');
				for (var n=0; n<names.length; n++) {
					var name = names[n];
					minions[name] = minions[name] || [];
					minions[name].push(minion);
				}
			}
			
			//get the jobs we care about
			var jobs = this.jobs[init];
			//sort the jobs by priority
			jobs.sort(function(a, b) {return a.order - b.order;}); //lowest order happens first

			//assign jobs to their minions if their minions exist
			start_assigns = (new Date()).getTime();
			for (var j=0; j<jobs.length; j++) {
				var job = jobs[j];
				if (minions[job.minion]) {
					//assign each  minion with the name job.minion the job
					for (var m=0; m<minions[job.minion].length; m++) {
						try {
							job.assign(minions[job.minion][m]);
							//YAHOO.log("Assigned " + minion, 'time', 'Overlord');
						} catch (err) {
							YAHOO.log("***** Overlord: Assignment of the job "+job.minion+" failed on the minion #"+minions[job.minion][m].id+"."+minions[job.minion][m].className, 'error');
							YAHOO.log(err, 'error');
							console.error(err);
							throw err;
						}
					}
				}
			}
		}	
		
		duration_begin = ((new Date()).getTime() - start_begin);
		duration_assigns = ((new Date()).getTime() - start_assigns);
		if (init == 'available') {
			YAHOO.log("Assignment of " + root.getAttribute('minion_name') + " completed in " + duration_begin + "ms (" + duration_assigns + "ms for assigns).", 'time', 'Overlord');
		} else {
			YAHOO.log("Assignment for initialization period " + init + " completed in " + duration_begin + "ms (" + duration_assigns + "ms for assigns).", 'time', 'Overlord');
		}
	},
	findMinions: function(root) {
		root = [].concat(root);
		var found = [];
		for (var i=0; i<root.length; i++) {
			if (root[i] && Overlord.isMinion(root[i])) {
				found.push(root[i]); //getElementsBy doesn't include its root when it is searching
			}
			found = found.concat(YAHOO.util.Dom.getElementsBy(Overlord.isMinion, null, root[i]));
		}
		return found;
	},
	isMinion: function(element) {
		return element.getAttribute('minion_name');
	},
	toString: function() {
		var targetedNames = [];
		for (var j=0; j<this.jobs.length; j++) {
			targetedNames.push(this.jobs[j].minion);
		}
		return "Overlord<" + targetedNames.join(', ')+ ">";
		
	}
};

Overlord.Job = function(description) {
	this.tasks = {};
	for (task in description) {
		//Assume any task that is a function and we don't have a default 
		//for is an event to register.  The task click would contain a function 
		//for onclick.
		if (task == "priority") { //priority was used in ScriptManager, order should be used for Overlord
			if (console) {
				console.error(description);
			}
			throw "Attempted to use priority in an Overlord Job for " + description["minion"] + ".";
		} else if (this[task] === undefined && Function.prototype.isPrototypeOf(description[task])) {
			this.addTask(task, description[task]);
		} else {
			this[task] = description[task]; //override default properties
		}
	}
};

Overlord.Job.prototype = {
	minion: null, //the name of the minion this job should be assigned to
	load: null, //function called on load at page load or via ajax
	unload: null, //function called when the element is removed or unloaded
	scope: null, //optional object to execute in the scope of, if it is missing the minion will be used as a scope
	order: 0, //set this value to adjust the order the script is excuted in, lower numbers happen first
	tasks: null, //a map of event names to handling functions
	init: 'dom', //(load (the window.onload event) | dom (yui's ondomready event) | available (as soon as the element is in the dom)) 
	assign: function(minion) {
		
		var scope = this.scope || minion;
		if (this.load) {
			this.load.call(scope, minion);
		}
		for (task in this.tasks) {
			YAHOO.util.Event.on(minion, task, this.tasks[task], minion, scope);
		}
	},
	unassign: function(minion) {
		if (this.unload) {
			var scope = this.scope || minion;
			this.unload.call(scope, minion);
		}
	},
	addTask: function(name, task) {
		this.tasks[name] = task;
	}
};

YAHOO.util.Event.on(window, 'load', function() {Overlord.summonMinions(null, 'load');});
YAHOO.util.Event.onDOMReady(function() {Overlord.summonMinions(null, 'dom');});
