--!strict
--[[
	Scheduler. Real time passes here, so periods are tiny and every wait has
	slack -- a test that asserts exact timing on a shared machine is a test
	that fails in CI for no reason.
]]
local task = require("@lute/task")

local Scheduler = require("@discord/scheduler")
local h = require("./harness")

local sched = Scheduler.new()

----------------------------------------------------------------------------
-- One-shot
----------------------------------------------------------------------------
local fired = 0
sched:after(0.05, function()
	fired += 1
end, "one-shot")

h.equals("job is counted before it runs", sched:count(), 1)
local remaining = sched:timeUntil(1)
h.check("timeUntil is in range before firing", remaining ~= nil and remaining <= 0.05)

task.wait(0.15)
h.equals("one-shot ran", fired, 1)
h.equals("one-shot deregistered itself", sched:count(), 0)
h.equals("timeUntil is nil once it has run", sched:timeUntil(1), nil)

task.wait(0.1)
h.equals("one-shot did not run twice", fired, 1)

----------------------------------------------------------------------------
-- Cancellation
----------------------------------------------------------------------------
local neverRan = true
local cancelId = sched:after(0.05, function()
	neverRan = false
end, "cancelled")
h.equals("cancel reports it removed the job", sched:cancel(cancelId), true)
h.equals("cancelling twice is false, not an error", sched:cancel(cancelId), false)
h.equals("cancelling an unknown id is false", sched:cancel(9999), false)
task.wait(0.15)
h.check("a cancelled job never ran", neverRan)

----------------------------------------------------------------------------
-- Repeating
----------------------------------------------------------------------------
local ticks = 0
local repeatId = sched:every(0.05, function()
	ticks += 1
end, "repeating")
task.wait(0.28)
h.check(`repeating job ticked more than once (got {ticks})`, ticks >= 3)
h.equals("repeating job is still registered", sched:count(), 1)

sched:cancel(repeatId)
local atCancel = ticks
task.wait(0.15)
h.equals("cancel stops a repeating job", ticks, atCancel)
h.equals("cancelled repeat deregistered", sched:count(), 0)

----------------------------------------------------------------------------
-- `immediate` runs the first tick without waiting a period
----------------------------------------------------------------------------
local immediateTicks = 0
local immediateId = sched:every(10, function()
	immediateTicks += 1
end, "immediate", true)
task.wait(0.05)
h.equals("immediate ran straight away", immediateTicks, 1)
sched:cancel(immediateId)

----------------------------------------------------------------------------
-- A throwing job must not kill the schedule
----------------------------------------------------------------------------
local attempts = 0
local badId = sched:every(0.05, function()
	attempts += 1
	error("this job is broken")
end, "throws")
task.wait(0.24)
h.check(`a throwing job kept its schedule (ran {attempts} times)`, attempts >= 3)
sched:cancel(badId)

-- And a throwing one-shot must not take the process down.
local after = false
sched:after(0.02, function()
	error("boom")
end, "throwing one-shot")
sched:after(0.08, function()
	after = true
end, "runs after the throw")
task.wait(0.2)
h.check("a later job still ran after an earlier one threw", after)

----------------------------------------------------------------------------
-- Drift: a job whose work overruns its period skips, it does not stack
----------------------------------------------------------------------------
local slowTicks = 0
local slowId = sched:every(0.05, function()
	slowTicks += 1
	task.wait(0.12) -- more than two whole periods
end, "slow")
task.wait(0.5)
sched:cancel(slowId)
-- Without skip logic this would fire back-to-back forever trying to catch up.
h.check(`slow job skipped missed ticks rather than stacking (got {slowTicks})`, slowTicks <= 6)

----------------------------------------------------------------------------
-- Validation and shutdown
----------------------------------------------------------------------------
h.throws("a zero period is rejected", "greater than zero", function()
	sched:every(0, function() end)
end)
h.throws("a negative period is rejected", "greater than zero", function()
	sched:every(-1, function() end)
end)

local survivor = false
sched:after(0.05, function()
	survivor = true
end, "should not survive stop")
sched:stop()
h.equals("stop cleared every job", sched:count(), 0)
task.wait(0.15)
h.check("a job scheduled before stop did not run", not survivor)
h.throws("a stopped scheduler refuses new jobs", "stopped", function()
	sched:after(1, function() end)
end)

-- Built at runtime; a literal 0/0 trips the linter.
local NAN = tonumber("nan") or (math.huge - math.huge)
local guarded = Scheduler.new()
h.throws("a NaN period is refused rather than spinning", "finite", function()
	guarded:every(NAN, function() end)
end)
h.throws("a NaN delay is refused", "finite", function()
	guarded:after(NAN, function() end)
end)
guarded:stop()

h.finish()
