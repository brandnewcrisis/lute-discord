--!strict
-- Exercises the interaction wrapper against a recording stub instead of the
-- network. The response state machine is the part worth testing: which route
-- a reply takes depends on what was sent before it.
local Const = require("@discord/const")
local Interaction = require("@discord/interaction")
local h = require("./harness")

type Call = { kind: string, arg: any }

local function stubClient(): (any, { Call })
	local calls: { Call } = {}
	local client = {
		api = {
			interactions = {
				createResponse = function(_id: string, _token: string, kind: number, data: any)
					table.insert(calls, { kind = `response:{kind}`, arg = data })
				end,
				editOriginalResponse = function(_app: string, _token: string, payload: any): any
					table.insert(calls, { kind = "edit", arg = payload })
					return { id = "msg" }
				end,
				createFollowup = function(_app: string, _token: string, payload: any): any
					table.insert(calls, { kind = "followup", arg = payload })
					return { id = "msg2" }
				end,
			},
		},
	}
	return client, calls
end

local function command(data: any): any
	return {
		id = "1",
		application_id = "app",
		token = "tok",
		type = Const.InteractionType.APPLICATION_COMMAND,
		version = 1,
		guild_id = "guild",
		channel_id = "chan",
		member = { roles = {}, joined_at = "", permissions = "8192", user = { id = "user", username = "u" } },
		app_permissions = "2048",
		data = data,
	}
end

-- Routing: subcommands live in the options array, not in the name.
local flat = Interaction.new((stubClient()), command({ name = "ping" }))
h.equals("plain command path", flat:commandPath(), "ping")

local sub = Interaction.new(
	(stubClient()),
	command({
		name = "role",
		options = {
			{
				name = "add",
				type = Const.OptionType.SUB_COMMAND,
				options = { { name = "user", type = Const.OptionType.USER, value = "42" } },
			},
		},
	})
)
h.equals("subcommand path", sub:commandPath(), "role add")
h.equals("options come from the leaf", sub:opt("user"), "42")

local grouped = Interaction.new(
	(stubClient()),
	command({
		name = "config",
		options = {
			{
				name = "roles",
				type = Const.OptionType.SUB_COMMAND_GROUP,
				options = {
					{
						name = "add",
						type = Const.OptionType.SUB_COMMAND,
						options = { { name = "role", type = Const.OptionType.ROLE, value = "7" } },
					},
				},
			},
		},
	})
)
h.equals("group path is two levels deep", grouped:commandPath(), "config roles add")
h.equals("leaf options still resolve", grouped:opt("role"), "7")

-- Resolved objects ride along on the payload; no fetch should be needed.
local resolved = Interaction.new(
	(stubClient()),
	command({
		name = "userinfo",
		options = { { name = "who", type = Const.OptionType.USER, value = "99" } },
		resolved = {
			users = { ["99"] = { id = "99", username = "target" } },
			members = { ["99"] = { roles = { "1" }, joined_at = "2020" } },
		},
	})
)
h.equals("getUser resolves", (resolved:getUser("who") :: any).username, "target")
h.equals("getMember splices the user back in", ((resolved:getMember("who") :: any).user :: any).id, "99")
h.equals("missing option is nil", resolved:getUser("nobody"), nil)
h.equals("opt default", resolved:opt("nobody", "fallback"), "fallback")

-- Precomputed permission strings.
h.equals("member permissions parse", flat:memberPermissions():toString(), "8192")
h.equals("app permissions parse", flat:appPermissions():toString(), "2048")

-- Modal values arrive nested two rows deep.
local modal = Interaction.new(
	(stubClient()),
	command({
		custom_id = "form",
		components = {
			{ type = 1, components = { { custom_id = "title", value = "Hello" } } },
			{ type = 1, components = { { custom_id = "body", value = "World" } } },
		},
	})
)
h.equals("modal values flatten", modal:modalValues().body, "World")

-- The state machine.
local client, calls = stubClient()
local ix = Interaction.new(client, command({ name = "ping" }))
ix:reply("first")
h.equals("first reply is a channel message", calls[1].kind, `response:{Const.InteractionCallback.CHANNEL_MESSAGE_WITH_SOURCE}`)
ix:reply("second")
h.equals("a second reply becomes a follow-up", calls[2].kind, "followup")

local client2, calls2 = stubClient()
local deferred = Interaction.new(client2, command({ name = "slow" }))
deferred:defer(true)
h.equals("defer sends the deferred callback", calls2[1].kind, `response:{Const.InteractionCallback.DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE}`)
h.equals("defer carries the ephemeral flag", calls2[1].arg.flags, Const.MessageFlag.EPHEMERAL)
deferred:reply("done")
h.equals("a reply after defer edits the placeholder", calls2[2].kind, "edit")
deferred:reply("again")
h.equals("and the one after that is a follow-up", calls2[3].kind, "followup")

local client3, calls3 = stubClient()
local ephemeral = Interaction.new(client3, command({ name = "x" }))
ephemeral:replyEphemeral("hidden")
h.equals("replyEphemeral sets the flag", calls3[1].arg.flags, Const.MessageFlag.EPHEMERAL)

local client4 = (stubClient())
local acked = Interaction.new(client4, command({ name = "x" }))
acked:reply("x")
h.throws("a modal cannot follow a reply", "must be the first response", function()
	acked:showModal({ custom_id = "m", title = "t", components = {} })
end)

local client5, calls5 = stubClient()
local auto = Interaction.new(client5, command({ name = "x" }))
local many = {}
for index = 1, 40 do
	table.insert(many, { name = tostring(index), value = tostring(index) })
end
auto:autocomplete(many)
h.equals("autocomplete is capped at 25", #calls5[1].arg.choices, 25)

h.finish()
