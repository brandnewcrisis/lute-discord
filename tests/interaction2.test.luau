--!strict
-- The narrowing helpers: required options and guild/channel ids, which the
-- schema guarantees but Luau cannot see.
local Const = require("@discord/const")
local Interaction = require("@discord/interaction")
local h = require("./harness")

local function make(overrides: any, remove: { string }?): any
	local raw: any = {
		id = "1",
		application_id = "app",
		token = "tok",
		type = Const.InteractionType.APPLICATION_COMMAND,
		version = 1,
		guild_id = "guild",
		channel_id = "chan",
		member = { roles = {}, joined_at = "", permissions = "0", user = { id = "user", username = "u" } },
		data = {
			name = "mod",
			options = {
				{ name = "who", type = Const.OptionType.USER, value = "99" },
				{ name = "outsider", type = Const.OptionType.USER, value = "55" },
				{ name = "role", type = Const.OptionType.ROLE, value = "7" },
				{ name = "where", type = Const.OptionType.CHANNEL, value = "c1" },
				{ name = "proof", type = Const.OptionType.ATTACHMENT, value = "a1" },
				{ name = "reason", type = Const.OptionType.STRING, value = "spam" },
			},
			resolved = {
				users = {
					["99"] = { id = "99", username = "target" },
					["55"] = { id = "55", username = "stranger" },
				},
				members = { ["99"] = { roles = {}, joined_at = "2020" } },
				roles = { ["7"] = { id = "7", name = "mod" } },
				channels = { c1 = { id = "c1", name = "general" } },
				attachments = { a1 = { id = "a1", filename = "log.txt", size = 1, url = "u", proxy_url = "p" } },
			},
		},
	}
	for key, value in overrides do
		raw[key] = value
	end
	-- A nil in a table constructor is no key at all, so removals are named.
	for _, key in remove or {} do
		raw[key] = nil
	end
	local client: any = { api = {} }
	return Interaction.new(client, raw)
end

local ix = make({})
h.equals("requireOpt", ix:requireOpt("reason"), "spam")
h.equals("requireUser", ix:requireUser("who").username, "target")
h.equals("requireMember splices the user in", (ix:requireMember("who").user :: any).id, "99")
h.equals("requireRole", ix:requireRole("role").name, "mod")
h.equals("requireChannel", (ix:requireChannel("where") :: any).name, "general")
h.equals("requireAttachment", ix:requireAttachment("proof").filename, "log.txt")
h.equals("requireGuildId", ix:requireGuildId(), "guild")
h.equals("requireChannelId", ix:requireChannelId(), "chan")

for _, getter in { "requireOpt", "requireUser", "requireMember", "requireRole", "requireChannel", "requireAttachment" } do
	h.throws(`{getter} names the missing option`, 'option "absent" is required but was not supplied', function()
		(ix :: any)[getter](ix, "absent")
	end)
end
h.throws("requireMember tells a non-member from a missing option", "not a member of this server", function()
	ix:requireMember("outsider")
end)

local dm = make({ user = { id = "user", username = "u" } }, { "guild_id", "member" })
h.throws("requireGuildId in a DM", "mark the command guildOnly", function()
	dm:requireGuildId()
end)
local noChannel = make({}, { "channel_id" })
h.throws("requireChannelId without a channel", "no channel id", function()
	noChannel:requireChannelId()
end)

h.finish()
