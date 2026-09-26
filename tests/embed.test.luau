--!strict
local Embed = require("@discord/embed")
local h = require("./harness")

local embed = Embed.new()
	:setTitle("Title")
	:setDescription("Body")
	:setColor("#5865F2")
	:addField("a", "1", true)
	:addField("b", "2", true)

local data = embed:toJSON()
h.equals("title", data.title, "Title")
h.equals("hex colour parses", data.color, 0x5865F2)
h.equals("fields", #(data.fields :: any), 2)
h.equals("inline preserved", (data.fields :: any)[1].inline, true)
h.equals("length counts every text field", embed:length(), #"Title" + #"Body" + 4)

h.check("timestamp is ISO-8601", string.match(Embed.new():setTimestamp(0):toJSON().timestamp :: string, "^1970%-01%-01T00:00:00Z$") ~= nil)

h.throws("title limit", "limit is 256", function()
	Embed.new():setTitle(string.rep("x", 257))
end)
h.throws("description limit", "limit is 4096", function()
	Embed.new():setDescription(string.rep("x", 4097))
end)
h.throws("field value limit", "limit is 1024", function()
	Embed.new():addField("n", string.rep("x", 1025))
end)
h.throws("empty field value", "empty value", function()
	Embed.new():addField("n", "")
end)
h.throws("field count", "25 fields", function()
	local many = Embed.new()
	for index = 1, 26 do
		many:addField(`f{index}`, "v")
	end
end)

-- The 6000 total is checked at build time, because it is the one limit that
-- no single setter can see.
h.throws("total budget", "6000", function()
	local big = Embed.new():setDescription(string.rep("x", 4000))
	for index = 1, 3 do
		big:addField(`f{index}`, string.rep("y", 1000))
	end
	big:toJSON()
end)

local trimmed = Embed.new():addTrimmedField("n", string.rep("x", 2000)):toJSON()
h.equals("trimmed field fits", utf8.len((trimmed.fields :: any)[1].value), 1024)

h.equals("#rgb shorthand expands like CSS", Embed.new():setColor("#fff"):toJSON().color, 0xFFFFFF)
h.throws("a bad colour is an error, not a silent blurple", "is not a colour", function()
	Embed.new():setColor("#zzzzzz")
end)

h.finish()
