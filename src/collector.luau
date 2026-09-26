--!strict
--[[
	Collectors: wait for component clicks or messages that match a filter.

	A button is only useful if something is listening for it, and the listener
	almost always wants to be scoped -- to one message, to the person who ran
	the command, for a limited time, for a limited number of clicks. Without
	that scope you get the two classic bugs: anyone can press someone else's
	buttons, and a handler registered for a one-off message lives forever.

	A collector is registered with the client, receives interactions the
	client routes to it, and unregisters itself on timeout or when its limit
	is reached. `onEnd` always runs exactly once, whichever way it ended, so
	the "disable the buttons now" cleanup has a single home.

	What arrives is an `Interaction`: component clicks and modal submits are
	what the client routes here. The message-shaped lookups in `matches` are
	kept so a message payload fed in by hand still gates correctly, but
	nothing in the library pushes one.
]]
local task = require("@lute/task")

local Interaction = require("@discord/interaction")
local Log = require("@discord/log")
local Spec = require("@discord/spec")
local Util = require("@discord/util")

--- Reads a nested field without tripping over a missing intermediate.
local function pluck(value: unknown, ...: string): any
	local node = value
	for index = 1, select("#", ...) do
		if type(node) ~= "table" then
			return nil
		end
		node = (node :: { [string]: any })[select(index, ...)]
	end
	return node
end

local Collector = {}
Collector.__index = Collector

--- What a collector collects.
export type Event = Interaction.Interaction

export type Options = {
	--- Only collect from this message. Almost always what you want.
	messageId: string?,
	--- Only collect from this channel.
	channelId: string?,
	--- Only collect from this user.
	userId: string?,
	--- Arbitrary extra test. Return false to ignore the event.
	filter: ((Event) -> boolean)?,
	--- Seconds before the collector ends itself. Defaults to 120.
	timeout: number?,
	--- Stop after this many collected events.
	max: number?,
	onCollect: ((Event) -> ())?,
	--- Runs once when the collector stops. `reason` is "timeout", "max",
	--- "stopped", or whatever was passed to `stop`.
	onEnd: ((reason: string, collected: { Event }) -> ())?,
	--[[
		The ephemeral reply to someone else clicking this collector's
		message, when `messageId` and `userId` are both set. Defaults to
		"These buttons aren't for you."; `false` lets the click fall
		through to the other handlers instead.
	]]
	othersMessage: (string | false)?,
}

local OPTION_KEYS = Spec.keys({
	"messageId",
	"channelId",
	"userId",
	"filter",
	"timeout",
	"max",
	"onCollect",
	"onEnd",
	"othersMessage",
})
local OPTION_ALIASES = {
	message = "messageId",
	channel = "channelId",
	user = "userId",
	time = "timeout",
	limit = "max",
	onStop = "onEnd",
	onClick = "onCollect",
}

local DEFAULT_OTHERS_MESSAGE = "These buttons aren't for you."
local ERROR_MESSAGE = "Something went wrong handling that."

export type Collector = typeof(setmetatable(
	{} :: {
		client: Host,
		options: Options,
		collected: { Event },
		ended: boolean,
		reason: string?,
		lastEvent: Event?,
		startedAt: Util.Instant,
		--- Set the moment the `max`th event is taken, before any user code
		--- runs, so a second event arriving during that code is refused.
		full: boolean,
	},
	{} :: typeof(Collector)
))

--[[
	The part of the client a collector needs, named structurally.

	`@discord/client` requires this module, so this module cannot require it
	back. Registration is the whole of the relationship, so registration is
	all this asks for.
]]
export type Host = { _collectors: { [Collector]: boolean } }

function Collector.new(client: Host, options: Options): Collector
	Spec.check(options, OPTION_KEYS, "collector", OPTION_ALIASES)
	--[[
		The client offers every component click and modal submit to each
		collector before any prefix route, so one that is scoped to neither a
		message nor a filter takes clicks meant for everything else in the
		bot -- `channelId` and `userId` narrow that, but do not stop it.
		Legitimate (a "next click from this user" wait), but far more often
		a forgotten `messageId`, which is otherwise a silent bug.
	]]
	if options.messageId == nil and options.filter == nil then
		local within = if options.channelId ~= nil and options.userId ~= nil
			then " in its channel from its user"
			elseif options.channelId ~= nil then " in its channel"
			elseif options.userId ~= nil then " from its user"
			else ""
		Log.warn(
			`collector has no messageId or filter, so it takes every component click and modal submit{within} `
				.. "and swallows the ones meant for other handlers; set messageId, or a filter on the custom id"
		)
	end
	local self = setmetatable({
		client = client,
		options = options,
		collected = {} :: { Event },
		ended = false,
		reason = nil :: string?,
		lastEvent = nil :: Event?,
		startedAt = Util.now(),
		full = false,
	}, Collector)

	client._collectors[self] = true

	local timeout = options.timeout or 120
	if timeout > 0 then
		-- Sliced rather than `task.delay`: an uncancellable two-minute timer
		-- would hold a stopped bot open until it fired.
		task.spawn(function()
			local elapsed = Util.sleepWhile(timeout, function(): boolean
				return not self.ended
			end)
			if elapsed then
				Collector.stop(self, "timeout")
			end
		end)
	end

	return self
end

--[[
	How an event relates to this collector: "match" (collect it), "other"
	(on this collector's message, passing every test but the user one --
	someone else pressed the owner's button) or "miss".

	The filter still runs for "other", so a message whose own buttons are
	partly served elsewhere (a page carrying extra buttons, say) only turns
	away clicks the collector would otherwise have taken.
]]
local function classify(self: Collector, event: Event): "match" | "other" | "miss"
	if self.ended or self.full then
		return "miss"
	end
	local options = self.options
	if options.messageId ~= nil then
		local messageId = pluck(event, "raw", "message", "id") or pluck(event, "id")
		if messageId ~= options.messageId then
			return "miss"
		end
	end
	if options.channelId ~= nil then
		local channelId = pluck(event, "channelId") or pluck(event, "channel_id")
		if channelId ~= options.channelId then
			return "miss"
		end
	end
	local wrongUser = false
	if options.userId ~= nil then
		local userId = pluck(event, "user", "id") or pluck(event, "author", "id")
		wrongUser = userId ~= options.userId
		-- Only a click on the collector's own message can be "someone
		-- else's"; anywhere else it is simply not ours.
		if wrongUser and options.messageId == nil then
			return "miss"
		end
	end
	-- The cast is Luau's, not ours: refining `filter` out of `nil` leaves a
	-- type it declines to call. Naming the signature is the way through, and
	-- it is at least the real signature.
	local filter = options.filter
	if filter ~= nil and not (filter :: (Event) -> boolean)(event) then
		return "miss"
	end
	return if wrongUser then "other" else "match"
end

--- Decides whether an event belongs to this collector.
function Collector.matches(self: Collector, event: Event): boolean
	return classify(self, event) == "match"
end

--- The ephemeral "not yours" text for this collector, or nil when off.
local function othersMessage(options: Options): string?
	local text = options.othersMessage
	if text == false then
		return nil
	end
	if type(text) == "string" then
		return text
	end
	return DEFAULT_OTHERS_MESSAGE
end

--[[
	Answers an interaction whose `onCollect` threw, mirroring what the
	client does for a failed handler: without it, an unanswered click shows
	"This interaction failed", and a deferred one spins forever.
]]
local function apologise(event: Event)
	local ok, err = pcall(function()
		if event.deferred then
			Interaction.editReply(event, { content = ERROR_MESSAGE })
		elseif event.acknowledged then
			Interaction.followUp(event, { content = ERROR_MESSAGE, ephemeral = true })
		else
			Interaction.replyEphemeral(event, ERROR_MESSAGE)
		end
	end)
	if not ok then
		Log.warn(`collector could not report a handler failure: {tostring(err)}`)
	end
end

--[[
	Feeds an event in. Returns true if it was collected.

	The slot is claimed before `onCollect` runs. That handler nearly always
	yields -- `ix:update` is an HTTP call -- and a double-click delivers a
	second event while the first is still in flight; checking `max` after
	the handler would let both through a `max = 1` collector.

	`onCollect` runs on its own task, like any command handler, so a slow
	one holds up neither the shard nor the next event. When the collector
	fills, it stops once that last handler has finished, so `onEnd` (which
	typically disables the buttons) never races the handler's own edit.
]]
function Collector.push(self: Collector, event: Event): boolean
	local verdict = classify(self, event)
	if verdict == "other" then
		--[[
			Someone pressed a button that belongs to another user. Falling
			through would reach the prefix routes and, with none matching,
			a silent acknowledgement -- the button "does nothing" for them.
			Telling them why, and consuming the event, is the useful answer.
		]]
		local text = othersMessage(self.options)
		if text == nil then
			return false
		end
		task.spawn(function()
			local ok, err = pcall(Interaction.replyEphemeral, event, text)
			if not ok then
				Log.warn(`collector could not answer a click from another user: {tostring(err)}`)
			end
		end)
		return true
	elseif verdict == "miss" then
		return false
	end
	table.insert(self.collected, event)
	self.lastEvent = event
	local max = self.options.max
	if max ~= nil and #self.collected >= max then
		self.full = true
	end
	local filled = self.full

	local onCollect = self.options.onCollect
	if onCollect == nil then
		if filled then
			Collector.stop(self, "max")
		end
		return true
	end
	task.spawn(function()
		-- User code: an error here must not kill the collector or the shard.
		local ok, err = xpcall(function(): boolean
			onCollect(event)
			return true
		end, function(message: unknown): string
			return debug.traceback(tostring(message), 2)
		end)
		if not ok then
			Log.error(`collector handler failed:\n{tostring(err)}`)
			apologise(event)
		end
		if filled then
			Collector.stop(self, "max")
		end
	end)
	return true
end

function Collector.stop(self: Collector, reason: string?)
	if self.ended then
		return
	end
	self.ended = true
	self.reason = reason or "stopped"
	self.client._collectors[self] = nil
	local onEnd = self.options.onEnd
	if onEnd ~= nil then
		local ok, err = xpcall(function(): boolean
			(onEnd :: (string, { Event }) -> ())(self.reason :: string, self.collected)
			return true
		end, function(message: unknown): string
			return debug.traceback(tostring(message), 2)
		end)
		if not ok then
			Log.error(`collector onEnd failed:\n{tostring(err)}`)
		end
	end
end

--[[
	Blocks until the first event is collected, or the collector ends.

	Returns the event, or nil on timeout. Handy for a linear confirm/cancel
	flow, where callbacks would turn three lines into three functions.

	Polling rather than a condition variable because Lute's scheduler has no
	primitive to wake one thread from another; 20ms of latency on a human
	pressing a button is not observable.
]]
function Collector.await(self: Collector): Event?
	while not self.ended and #self.collected == 0 do
		task.wait(0.02)
	end
	return self.collected[1]
end

return Collector
