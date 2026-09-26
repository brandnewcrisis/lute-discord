--!strict
local Const = require("@discord/const")
local Embed = require("@discord/embed")
local Payload = require("@discord/payload")
local Types = require("@discord/types")
local h = require("./harness")

h.equals("a bare string becomes content", Payload.message("hi").content, "hi")

local ephemeral = Payload.message({ content = "x", ephemeral = true })
h.equals("ephemeral becomes a flag", ephemeral.flags, Const.MessageFlag.EPHEMERAL)
h.equals("the convenience key is removed", ephemeral.ephemeral, nil)

local silent = Payload.message({ content = "x", silent = true, ephemeral = true })
h.equals(
	"flags combine",
	silent.flags,
	bit32.bor(Const.MessageFlag.EPHEMERAL, Const.MessageFlag.SUPPRESS_NOTIFICATIONS)
)

local built = Payload.message({ embeds = { Embed.new():setTitle("T") } })
h.equals("builders are unwrapped", h.some(built.embeds)[1].title, "T")
h.equals("singular embed is accepted", h.some(Payload.message({ embed = Embed.new():setTitle("S") }).embeds)[1].title, "S")

h.check("the input is not mutated", (function()
	local input: Types.MessagePayload = { content = "x", ephemeral = true }
	Payload.message(input)
	return input.ephemeral == true
end)())

h.throws("an empty payload is rejected here, not by Discord", "payload is empty", function()
	Payload.message({ content = "" })
end)
h.check("components alone are enough", Payload.message({ components = { { type = 1 } } }) ~= nil)

h.equals("allowedMentions builds a parse list", #h.some(Payload.allowedMentions({ users = true }).parse), 1)
h.equals("NO_MENTIONS suppresses everything", #h.some(Payload.NO_MENTIONS.parse), 0)

-- An explicit id list and a parsed category are mutually exclusive: Discord
-- rejects a payload carrying both, so the id list has to win.
local scoped = Payload.allowedMentions({ users = true, userIds = { "1", "2" } })
h.equals("an id list drops the parsed category", #h.some(scoped.parse), 0)
h.equals("the id list survives", #h.some(scoped.users), 2)
local mixed = Payload.allowedMentions({ roleIds = { "9" }, everyone = true })
h.equals("everyone still parses alongside a role id list", #h.some(mixed.parse), 1)
h.equals("the role id list survives", #h.some(mixed.roles), 1)

-- The camelCase spelling must be translated. Left alone it reaches Discord as
-- an unknown field, is ignored, and the message pings everyone after all --
-- a silent failure in the expensive direction.
local translated = Payload.message({
	content = "hello @everyone",
	allowedMentions = Payload.NO_MENTIONS,
})
h.check("allowedMentions becomes allowed_mentions", translated.allowed_mentions ~= nil)
h.equals("the camelCase key is removed", translated.allowedMentions, nil)
h.equals("the suppression survives translation", #h.some(h.some(translated.allowed_mentions).parse), 0)

h.finish()
