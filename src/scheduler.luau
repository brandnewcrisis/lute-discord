--!strict
--[[
	Delayed and repeating jobs, with cancellation and a safety net.

	`task.delay` already exists in Lute, so the value here is the three things
	it does not do:

	  * A HANDLE. `task.delay` gives you nothing back, so a reminder cannot be
	    cancelled and a repeating job cannot be stopped. Every job here has an
	    id, and `cancel` works from anywhere.
	  * CONTAINMENT. A throw inside a `task.delay` callback is unhandled and
	    kills that task silently -- and for a repeating job, kills the repeat
	    with it. Jobs here run under `xpcall`: one bad tick is logged and the
	    schedule survives.
	  * DRIFT CONTROL. Chaining `task.delay(60, ...)` from inside the callback
	    means each period is 60 seconds PLUS however long the work took, so a
	    "every minute" job run 1440 times a day slides by however long the
	    sum of its own runtimes is. `every` schedules against the wall clock
	    it started from, and skips a tick rather than running late twice.

	=========================================================================
	THIS IS IN-MEMORY, AND THAT IS A DESIGN CHOICE
	=========================================================================

	Jobs do not survive a restart. Making them durable would mean a store, a
	serialisable payload, and a decision about what "the bot was down when it
	was due" means -- all of which depend on the job. A reminder wants to
	fire late; a "post the daily bounty at 9am" job wants to be skipped.

	So durability lives with the caller, which knows the answer: persist the
	due time yourself (see `@discord/storage`) and re-arm on boot.
	`docs/utilities.md` has a reminder example that does exactly that.
]]
local task = require("@lute/task")

local Log = require("@discord/log")
local Util = require("@discord/util")

local Scheduler = {}
Scheduler.__index = Scheduler

export type Job = {
	id: number,
	--- For logs. Defaults to "job <id>".
	label: string,
	--- Seconds between runs for a repeating job, nil for a one-shot.
	period: number?,
	--- Monotonic instant the job is next due.
	dueAt: number,
	fn: () -> (),
	cancelled: boolean,
	runs: number,
}

export type Scheduler = typeof(setmetatable(
	{} :: {
		jobs: { [number]: Job },
		_nextId: number,
		_running: boolean,
	},
	{} :: typeof(Scheduler)
))

function Scheduler.new(): Scheduler
	return setmetatable({
		jobs = {},
		_nextId = 1,
		_running = true,
	}, Scheduler)
end

--- Monotonic seconds since process start. `Util.now` returns an opaque
--- instant; `Util.since` on a fixed origin turns it into a number we can
--- do arithmetic on.
local ORIGIN = Util.now()
local function clock(): number
	return Util.since(ORIGIN)
end

Scheduler.clock = clock

local function run(self: Scheduler, job: Job)
	if job.cancelled or not self._running then
		return
	end
	job.runs += 1
	local ok, err = xpcall(function(): boolean
		job.fn()
		return true
	end, function(message: any): string
		return debug.traceback(tostring(message), 2)
	end)
	if not ok then
		-- Logged, not rethrown: a repeating job that throws once should keep
		-- its schedule, and a one-shot that throws should not take the
		-- process with it.
		Log.error(`scheduled job "{job.label}" failed:\n{tostring(err)}`)
	end
end

--[[
	Arms the underlying timer for one tick.

	Re-armed from inside the tick for repeating jobs rather than by a central
	loop. Each pending job wakes four times a second to see whether it has
	been cancelled -- the price of timers Lute cannot cancel, and negligible
	next to a single gateway heartbeat.
]]
local function arm(self: Scheduler, job: Job)
	local wait = math.max(0, job.dueAt - clock())
	-- Deferred so a zero-delay job still runs after `add` has returned its
	-- id, never inside the call that scheduled it.
	task.defer(function()
		-- Sliced, so `cancel` and `stop` actually release the process: a
		-- plain `task.delay` for a reminder a day out would keep a stopped
		-- bot alive for that day.
		Util.sleepWhile(wait, function(): boolean
			return not job.cancelled and self._running
		end)
		if job.cancelled or not self._running then
			self.jobs[job.id] = nil
			return
		end

		run(self, job)

		local period = job.period
		if period == nil or job.cancelled then
			self.jobs[job.id] = nil
			return
		end

		-- Advance against the ORIGINAL schedule, not against "now", so the
		-- job does not drift by its own runtime. If the work overran one or
		-- more whole periods, skip the missed ticks instead of firing them
		-- back to back -- a backlog of catch-up posts is never what anyone
		-- wanted.
		local now = clock()
		job.dueAt += period
		if job.dueAt <= now then
			local missed = math.floor((now - job.dueAt) / period) + 1
			job.dueAt += missed * period
			Log.debug(`scheduled job "{job.label}" skipped {missed} tick(s): it ran longer than its period`)
		end
		arm(self, job)
	end)
end

local function add(self: Scheduler, delay: number, period: number?, label: string?, fn: () -> ()): number
	if not self._running then
		error("scheduler is stopped", 3)
	end
	-- NaN slips past every comparison (`NaN <= 0` is false), and a NaN due
	-- time re-arms with a zero wait: a job that spins flat out. A computed
	-- delay like `tonumber(env) / x` is how one gets here.
	if delay ~= delay or delay == math.huge or delay == -math.huge then
		error(`a job's delay must be a finite number, got {delay}`, 3)
	end
	if period ~= nil and (period ~= period or period == math.huge) then
		error(`a repeating job's period must be a finite number, got {period}`, 3)
	end
	if period ~= nil and period <= 0 then
		error("a repeating job needs a period greater than zero", 3)
	end
	local id = self._nextId
	self._nextId += 1
	local job: Job = {
		id = id,
		label = label or `job {id}`,
		period = period,
		dueAt = clock() + math.max(0, delay),
		fn = fn,
		cancelled = false,
		runs = 0,
	}
	self.jobs[id] = job
	arm(self, job)
	return id
end

--- Runs `fn` once, `delay` seconds from now. Returns a job id for `cancel`.
function Scheduler.after(self: Scheduler, delay: number, fn: () -> (), label: string?): number
	return add(self, delay, nil, label, fn)
end

--[[
	Runs `fn` every `period` seconds, starting one period from now unless
	`immediate` is set.

	Returns a job id. Repeating jobs run until cancelled or until `stop`.
]]
function Scheduler.every(self: Scheduler, period: number, fn: () -> (), label: string?, immediate: boolean?): number
	local id = add(self, if immediate then 0 else period, period, label, fn)
	return id
end

--- Runs `fn` at a wall-clock unix timestamp. Past times run immediately,
--- which is the right default for a reminder re-armed after downtime.
function Scheduler.at(self: Scheduler, unixSeconds: number, fn: () -> (), label: string?): number
	return add(self, unixSeconds - Util.unix(), nil, label, fn)
end

--- Cancels a job. Safe to call on an id that has already run or been
--- cancelled, and safe to call from inside the job itself.
function Scheduler.cancel(self: Scheduler, id: number): boolean
	local job = self.jobs[id]
	if job == nil then
		return false
	end
	job.cancelled = true
	self.jobs[id] = nil
	return true
end

--- Seconds until `id` next runs, or nil if there is no such job.
function Scheduler.timeUntil(self: Scheduler, id: number): number?
	local job = self.jobs[id]
	if job == nil then
		return nil
	end
	return math.max(0, job.dueAt - clock())
end

function Scheduler.count(self: Scheduler): number
	local total = 0
	for _ in self.jobs do
		total += 1
	end
	return total
end

--- Cancels everything and refuses new jobs. Call from a shutdown path.
function Scheduler.stop(self: Scheduler)
	self._running = false
	for id, job in self.jobs do
		job.cancelled = true
		self.jobs[id] = nil
	end
end

return Scheduler
