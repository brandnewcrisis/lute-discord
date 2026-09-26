--!strict
--[[
	JSON for the Discord wire format, over `@std/json`.

	Three things the raw library leaves to the caller, all of which bite:

	  * Decoded OBJECTS carry a userdata sentinel key marking them as objects
	    rather than arrays. It is invisible until something iterates the table,
	    and then `for key in payload` hands you a userdata alongside the real
	    keys -- typically far from the decode site.
	  * A JSON `null` decodes to `json.null`, a userdata, not `nil`. Discord
	    nulls half the fields on every gateway payload (`t`, `s`, `guild_id`),
	    so without flattening, every single field read needs a null check.
	  * An empty Luau table serialises to `[]`. Discord rejects `[]` where it
	    wants an object, so payloads that need an explicit empty object have
	    to say so -- that is what `Json.object` is for.

	Decoding is destructive on purpose: it rewrites the tables in place rather
	than copying. Gateway payloads can be large (GUILD_CREATE for a big guild
	is megabytes) and they are consumed once.
]]
local json = require("@std/json")

local Json = {}

--- The sentinel to place in an outgoing payload when a field must be `null`
--- rather than absent -- clearing a nickname, removing a parent channel.
Json.null = json.null :: any

-- `json.object({})` is the only handle on the private object marker.
local OBJECT_KEY: any = (next(json.object({})))

--- Marks a table as a JSON object, so an empty one serialises `{}` not `[]`.
function Json.object(props: { [string]: any }?): any
	return json.object((props or {}) :: any)
end

function Json.encode(value: any, pretty: boolean?): string
	return json.serialize(value, pretty or false)
end

-- Rewrites `value` in place: drops the object marker, nils out JSON nulls.
local function flatten(value: any): any
	if value == json.null then
		return nil
	end
	if type(value) ~= "table" then
		return value
	end
	if OBJECT_KEY ~= nil then
		value[OBJECT_KEY] = nil
	end
	for key, item in value do
		if item == json.null then
			value[key] = nil
		elseif type(item) == "table" then
			flatten(item)
		end
	end
	return value
end

--- Decodes, returning `nil` plus a message instead of throwing. Every string
--- passed here came off a socket, so malformed input is an expected case.
function Json.decode(text: string): (any?, string?)
	if text == "" then
		return nil, "empty body"
	end
	local ok, result = pcall(json.deserialize, text)
	if not ok then
		return nil, tostring(result)
	end
	return flatten(result), nil
end

return Json
