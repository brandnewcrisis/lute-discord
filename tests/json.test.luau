--!strict
local Json = require("@discord/json")
local h = require("./harness")

-- The two traps this module exists for.
local payload = Json.decode('{"t":null,"s":3,"op":0,"d":{"guild_id":null,"roles":[]}}')
h.check("decoded", payload ~= nil)
h.equals("null becomes nil", payload.t, nil)
h.equals("numbers survive", payload.s, 3)
h.equals("nested null becomes nil", payload.d.guild_id, nil)

-- Iterating a decoded object must not hand back the userdata object marker.
local keys = {}
for key in payload do
	table.insert(keys, key)
	h.equals(`key {tostring(key)} is a string`, type(key), "string")
end
table.sort(keys)
h.equals("only the real keys remain", table.concat(keys, ","), "d,op,s")

-- Sorting decoded keys is where the sentinel used to blow up, far from here.
local ok = pcall(function()
	local names = {}
	for key in payload.d do
		table.insert(names, key)
	end
	table.sort(names)
end)
h.check("nested keys sort without erroring", ok)

h.equals("empty table encodes as an array", Json.encode({}), "[]")
h.equals("Json.object encodes as an object", Json.encode(Json.object()), "{}")
h.equals("explicit null encodes", Json.encode({ nick = Json.null }), '{ "nick": null}')
h.equals("arrays encode", Json.encode({ 1, 2, 3 }), "[1, 2, 3]")

local value, err = Json.decode("{not json")
h.check("malformed input returns an error rather than throwing", value == nil and err ~= nil)
local empty, emptyErr = Json.decode("")
h.check("empty body is an error, not a crash", empty == nil and emptyErr == "empty body")

h.finish()
