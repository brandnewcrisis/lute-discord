--!strict
--[[
	Catches misspelled keys in option tables.

		Spec.check(spec, BUTTON_KEYS, "button")

	Luau does not reject an unknown key in a table literal passed to a typed
	parameter, so `{ min_value = 2 }` where the option is `min` typechecks,
	runs, and is silently ignored -- the bug surfaces much later as "my limit
	does nothing". The builders call this at the top so the typo fails on the
	line that made it, with the likely intended key named.

	Suggestions come from three places, in order: an explicit alias table
	(Discord's wire names mapped to this library's, like `custom_id` -> `id`),
	the camelCase form of a snake_case key, and the nearest known key by edit
	distance.
]]
local blame = require("@discord/blame")

local Spec = {}

export type Keys = { [string]: boolean }

--- Builds a key set from a list, for the `allowed` argument.
function Spec.keys(list: { string }): Keys
	local out: Keys = {}
	for _, key in list do
		out[key] = true
	end
	return table.freeze(out)
end

local function distance(a: string, b: string): number
	if a == b then
		return 0
	end
	-- previous[j + 1] is the distance from a[1..i-1] to b[1..j].
	local previous = table.create(#b + 1, 0)
	for j = 1, #b + 1 do
		previous[j] = j - 1
	end
	for i = 1, #a do
		local current = { i }
		for j = 1, #b do
			local cost = if string.byte(a, i) == string.byte(b, j) then 0 else 1
			current[j + 1] = math.min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
		end
		previous = current
	end
	return previous[#b + 1]
end

local function camel(key: string): string
	return (string.gsub(key, "_(%l)", string.upper))
end

--- The key the caller probably meant, or nil.
function Spec.suggest(key: string, allowed: Keys, aliases: { [string]: string }?): string?
	local alias = aliases and aliases[key]
	if alias ~= nil and allowed[alias] then
		return alias
	end
	local camelled = camel(key)
	if camelled ~= key and allowed[camelled] then
		return camelled
	end
	local best, bestScore = nil, math.huge
	for candidate in allowed do
		local score = distance(string.lower(key), string.lower(candidate))
		if score < bestScore then
			best, bestScore = candidate, score
		end
	end
	-- Beyond two edits a "suggestion" is noise.
	if best ~= nil and bestScore <= math.min(2, math.floor(#key / 2)) then
		return best
	end
	return nil
end

--[[
	Errors on the first key in `spec` that is not in `allowed`, naming it
	and, when there is a plausible one, the key that was meant. Non-string
	keys (an array part) are left alone: some specs legitimately carry one.
]]
function Spec.check(spec: unknown, allowed: Keys, what: string, aliases: { [string]: string }?)
	-- `unknown` because every caller holds a closed record type (ButtonSpec,
	-- OptionExtra, ...), and Luau does not admit those as `{ [any]: any }`.
	if type(spec) ~= "table" then
		return
	end
	for key in spec :: { [any]: any } do
		if type(key) == "string" and not allowed[key] then
			local guess = Spec.suggest(key, allowed, aliases)
			local hint = if guess ~= nil then `; did you mean "{guess}"?` else ""
			error(`{what} has no option "{key}"{hint}`, blame())
		end
	end
end

return Spec
