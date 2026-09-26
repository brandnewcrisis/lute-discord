--!strict
-- Shared assertion helpers. Each test file prints one line per check and a
-- FAILURES marker the runner greps for.
local Harness = {}

local failures = 0
local total = 0

function Harness.check(name: string, condition: boolean)
	total += 1
	if condition then
		print(`ok   {name}`)
	else
		failures += 1
		print(`FAIL {name}`)
	end
end

function Harness.equals(name: string, actual: any, expected: any)
	total += 1
	if actual == expected then
		print(`ok   {name}`)
	else
		failures += 1
		print(`FAIL {name} -- expected {tostring(expected)}, got {tostring(actual)}`)
	end
end

--- Asserts that `fn` throws, and that the message contains `fragment`.
function Harness.throws(name: string, fragment: string, fn: () -> ())
	total += 1
	local ok, err = pcall(fn)
	if ok then
		failures += 1
		print(`FAIL {name} -- expected an error, none thrown`)
	elseif string.find(tostring(err), fragment, 1, true) == nil then
		failures += 1
		print(`FAIL {name} -- error did not mention "{fragment}": {tostring(err)}`)
	else
		print(`ok   {name}`)
	end
end

--[[
	Unwraps an optional, failing loudly if it is nil.

	Discord's shapes are honest about which fields can be absent, so a test
	reading `command.options[1]` has to narrow first. This does it in one
	place, and a nil here is itself a failure worth a clear message rather
	than an "attempt to index nil" three frames later.
]]
function Harness.some<T>(value: T?, what: string?): T
	if value == nil then
		error(`expected a value{if what then " for " .. what else ""}, got nil`, 2)
	end
	return value
end

function Harness.finish()
	if failures > 0 then
		print(`FAILURES: {failures} of {total}`)
	else
		print(`all {total} checks pass`)
	end
end

return Harness
