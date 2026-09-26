--!strict
-- Collectors gate on message, user and filter, and must end exactly once.
local task = require("@lute/task")

local Collector = require("@discord/collector")
local h = require("./harness")

local function fakeClient(): any
	return { _collectors = {} }
end

local function click(messageId: string, userId: string, customId: string): any
	return {
		id = "ix",
		user = { id = userId },
		data = { custom_id = customId },
		raw = { message = { id = messageId } },
	}
end

local client = fakeClient()
local collected = {}
local collector = Collector.new(client, {
	messageId = "m1",
	userId = "u1",
	timeout = 0,
	-- Off here so another user's click falls through; the default "not
	-- for you" reply is covered in dx.test.luau.
	othersMessage = false,
	onCollect = function(event: any)
		table.insert(collected, event.data.custom_id)
	end,
})

h.check("registers with the client", client._collectors[collector] == true)
h.check("wrong message is ignored", not collector:push(click("m2", "u1", "a")))
h.check("wrong user is ignored", not collector:push(click("m1", "u2", "a")))
h.check("matching event is collected", collector:push(click("m1", "u1", "a")))
h.equals("handler ran", collected[1], "a")

-- max ends the collector, and end runs once.
local ends = 0
local limited = Collector.new(fakeClient(), {
	max = 2,
	timeout = 0,
	onEnd = function(reason: string)
		ends += 1
		h.equals("end reason is max", reason, "max")
	end,
})
limited:push(click("m", "u", "1"))
limited:push(click("m", "u", "2"))
h.check("ends at max", limited.ended)
h.check("stops collecting after ending", not limited:push(click("m", "u", "3")))
limited:stop("again")
h.equals("onEnd runs exactly once", ends, 1)

-- A filter is the general escape hatch.
local filtered = Collector.new(fakeClient(), {
	timeout = 0,
	filter = function(event: any): boolean
		return string.sub(event.data.custom_id, 1, 5) == "vote:"
	end,
})
h.check("filter rejects", not filtered:push(click("m", "u", "other")))
h.check("filter accepts", filtered:push(click("m", "u", "vote:yes")))

-- A throwing handler must not take the collector with it.
local survived = Collector.new(fakeClient(), {
	timeout = 0,
	onCollect = function()
		error("handler blew up")
	end,
})
survived:push(click("m", "u", "x"))
h.check("collector survives a throwing handler", not survived.ended)

-- Timeout unregisters.
local timed = Collector.new(client, { timeout = 0.05 })
task.wait(0.2)
h.check("timeout ends the collector", timed.ended)
h.equals("timeout reason", timed.reason, "timeout")
h.check("unregistered on end", client._collectors[timed] == nil)

-- await returns the first event.
local awaited = Collector.new(fakeClient(), { timeout = 1 })
task.delay(0.05, function()
	awaited:push(click("m", "u", "pressed"))
end)
local event = awaited:await()
h.equals("await returns the event", h.some(event).data.custom_id, "pressed")

-- A double-click on a max = 1 collector: the handler yields (as an HTTP call
-- would), and the second click arrives while it is still running.
local handled, endedWith = 0, -1
local single = Collector.new(fakeClient(), {
	messageId = "m",
	max = 1,
	timeout = 0,
	onCollect = function(_event: any)
		handled += 1
		task.wait(0.05)
	end,
	onEnd = function(_reason: string, got: { any })
		endedWith = #got
	end,
})
h.check("first click is taken", single:push(click("m", "u", "a")))
h.check("second click during the handler is refused", not single:push(click("m", "u", "b")))
h.equals("onEnd waits for the handler", endedWith, -1)
task.wait(0.1)
h.equals("the handler ran once", handled, 1)
h.equals("onEnd saw exactly one event", endedWith, 1)

h.finish()
