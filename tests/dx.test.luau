--!strict
--[[
	Developer-experience affordances: typed option reads, `ix.client`'s
	reach, resolved select picks, typo-checked builder specs, collector
	manners, paginator pages from builder chains, permission names on a
	bitfield, and permission checks on members that arrive without `user`.

	Several checks here are TYPE-level: they pass by typechecking at all
	(`lute run tools/check.luau` covers this file), and the runtime half
	only confirms the value is right.
]]
local task = require("@lute/task")

local Bitfield = require("@discord/bitfield")
local Cache = require("@discord/cache")
local Client = require("@discord/client")
local Collector = require("@discord/collector")
local Components = require("@discord/components")
local Const = require("@discord/const")
local Embed = require("@discord/embed")
local Interaction = require("@discord/interaction")
local Log = require("@discord/log")
local Paginator = require("@discord/paginator")
local Permissions = require("@discord/permissions")
local Types = require("@discord/types")
local Fakes = require("./fakes")
local h = require("./harness")

type Call = { kind: number, body: any }

local function stubClient(): (any, { Call })
	local calls: { Call } = {}
	local client = {
		api = {
			interactions = {
				createResponse = function(_id: string, _token: string, kind: number, body: any)
					table.insert(calls, { kind = kind, body = body })
				end,
				editOriginalResponse = function(_app: string, _token: string, payload: any): any
					table.insert(calls, { kind = -1, body = payload })
					return { id = "orig" }
				end,
				createFollowup = function(_app: string, _token: string, payload: any): any
					table.insert(calls, { kind = -2, body = payload })
					return { id = "follow" }
				end,
				getOriginalResponse = function(): any
					return { id = "orig" }
				end,
			},
		},
		cache = Cache.new(true),
		user = { id = "bot", username = "bot" },
	}
	return client, calls
end

local function makeIx(client: any, kind: number, data: any, userId: string?, messageId: string?): Interaction.Interaction
	return Interaction.new(client, {
		id = "ix1",
		application_id = "app",
		token = "tok",
		type = kind,
		version = 1,
		guild_id = "g",
		channel_id = "c",
		member = { roles = {}, joined_at = "", user = { id = userId or "u1", username = "caller" } },
		message = if messageId ~= nil then { id = messageId } :: any else nil,
		data = data,
	} :: any)
end

local function command(options: any, resolvedData: any?): Interaction.Interaction
	return makeIx(
		(stubClient()),
		Const.InteractionType.APPLICATION_COMMAND,
		{ name = "cmd", options = options, resolved = resolvedData }
	)
end

local OT = Const.OptionType

----------------------------------------------------------------------------
-- 1. Typed option getters
----------------------------------------------------------------------------

local typed = command({
	{ name = "text", type = OT.STRING, value = "hello" },
	{ name = "count", type = OT.INTEGER, value = 3 },
	{ name = "ratio", type = OT.NUMBER, value = 0.5 },
	{ name = "flag", type = OT.BOOLEAN, value = false },
	{ name = "who", type = OT.USER, value = "42" },
})

-- Type-level: each getter's result is the named type, not `any`.
local text: string? = typed:getString("text")
local count: number? = typed:getInteger("count")
local ratio: number? = typed:getNumber("ratio")
local flag: boolean? = typed:getBoolean("flag")
h.equals("getString", text, "hello")
h.equals("getInteger", count, 3)
h.equals("getNumber", ratio, 0.5)
h.equals("getBoolean keeps false", flag, false)
h.equals("getNumber accepts an integer option", typed:getNumber("count"), 3)
h.equals("absent option is nil", typed:getString("nope"), nil)
h.equals("absent boolean is nil, not false", typed:getBoolean("nope"), nil)

h.throws("string read as integer", 'option "text" is a string, not an integer', function()
	typed:getInteger("text")
end)
h.throws("integer read as string", 'option "count" is an integer, not a string', function()
	typed:getString("count")
end)
h.throws("number read as integer", 'option "ratio" is a number, not an integer', function()
	typed:getInteger("ratio")
end)
h.throws("user read as boolean", 'option "who" is a user, not a boolean', function()
	typed:getBoolean("who")
end)
h.throws("mismatch blames the caller", "dx.test.luau", function()
	typed:getInteger("text")
end)

local requiredText: string = typed:requireString("text")
local requiredCount: number = typed:requireInteger("count")
local requiredRatio: number = typed:requireNumber("ratio")
local requiredFlag: boolean = typed:requireBoolean("flag")
h.equals("requireString", requiredText, "hello")
h.equals("requireInteger", requiredCount, 3)
h.equals("requireNumber", requiredRatio, 0.5)
h.equals("requireBoolean returns false, not a throw", requiredFlag, false)
h.throws("requireString on a missing option", 'option "gone" is required but was not supplied', function()
	typed:requireString("gone")
end)
h.throws("requireInteger on a missing option", 'option "gone" is required', function()
	typed:requireInteger("gone")
end)
h.throws("requireBoolean on a mismatch", 'option "text" is a string, not a boolean', function()
	typed:requireBoolean("text")
end)

-- Autocomplete: the focused numeric option carries the raw text so far.
local typing = makeIx((stubClient()), Const.InteractionType.APPLICATION_COMMAND_AUTOCOMPLETE, {
	name = "cmd",
	options = {
		{ name = "amount", type = OT.INTEGER, value = "12", focused = true },
		{ name = "partial", type = OT.NUMBER, value = "-", focused = true },
	},
})
h.equals("focused integer text is parsed", typing:getInteger("amount"), 12)
h.equals("unparseable partial number is nil", typing:getNumber("partial"), nil)

-- Mentionables.
local mention = command({
	{ name = "u", type = OT.MENTIONABLE, value = "7" },
	{ name = "r", type = OT.MENTIONABLE, value = "8" },
	{ name = "plainUser", type = OT.USER, value = "7" },
	{ name = "ghost", type = OT.MENTIONABLE, value = "999" },
	{ name = "s", type = OT.STRING, value = "x" },
}, {
	users = { ["7"] = { id = "7", username = "seven" } },
	members = { ["7"] = { roles = {}, joined_at = "2020" } },
	roles = { ["8"] = { id = "8", name = "eight" } },
})
local mu = h.some(mention:getMentionable("u"), "mentionable user")
-- Type-level: checking `kind` narrows to the user half, where `user` is
-- not optional.
if mu.kind == "user" then
	local username: string = mu.user.username
	h.equals("mentionable user resolves", username, "seven")
	local member = h.some(mu.member, "mentionable member")
	h.equals("mentionable member gets user spliced", (h.some(member.user)).id, "7")
else
	h.check("mentionable user resolves", false)
end
local mr = h.some(mention:getMentionable("r"), "mentionable role")
if mr.kind == "role" then
	h.equals("mentionable role resolves", mr.role.name, "eight")
else
	h.check("mentionable role resolves", false)
end
h.equals("mentionable id is carried", mr.id, "8")
h.equals("a user option reads as a mentionable", (h.some(mention:getMentionable("plainUser"))).kind, "user")
h.equals("absent mentionable is nil", mention:getMentionable("none"), nil)
h.equals("unresolved mentionable is nil", mention:getMentionable("ghost"), nil)
h.throws("string read as mentionable", 'option "s" is a string, not a mentionable', function()
	mention:getMentionable("s")
end)
h.equals("requireMentionable", mention:requireMentionable("r").id, "8")
h.throws("requireMentionable unresolved", "no resolved user or role", function()
	mention:requireMentionable("ghost")
end)
h.throws("requireMentionable missing", "is required", function()
	mention:requireMentionable("none")
end)

----------------------------------------------------------------------------
-- 2. ix.client carries the cache and the bot user
----------------------------------------------------------------------------

-- Type-level: a real Client is a ClientRef, and a handler can reach the
-- cache and the bot's user through `ix.client` without closing over it.
local function _asRef(client: Client.Client): Interaction.ClientRef
	return client
end
local function handler(ix: Interaction.Interaction): (Types.Guild?, string?)
	local guild = ix.client.cache:getGuild(ix.guildId)
	local me = ix.client.user
	return guild, if me ~= nil then me.id else nil
end
local refClient = stubClient()
Cache.putGuild(refClient.cache, { id = "g", name = "guild", owner_id = "1", roles = {} } :: any)
local guildSeen, botId = handler(makeIx(refClient, Const.InteractionType.APPLICATION_COMMAND, { name = "x" }))
h.equals("ix.client.cache reaches the cache", (h.some(guildSeen)).name, "guild")
h.equals("ix.client.user is the bot", botId, "bot")
h.check("asRef is referenced", type(_asRef) == "function")

----------------------------------------------------------------------------
-- 3. Resolved picks from a select on a message
----------------------------------------------------------------------------

local picked = makeIx((stubClient()), Const.InteractionType.MESSAGE_COMPONENT, {
	custom_id = "pick",
	component_type = Const.ComponentType.MENTIONABLE_SELECT,
	values = { "u2", "r1", "u1", "gone" },
	resolved = {
		users = { u1 = { id = "u1", username = "one" }, u2 = { id = "u2", username = "two" } },
		members = { u2 = { roles = {}, joined_at = "2021" }, u1 = { roles = {}, joined_at = "2020" } },
		roles = { r1 = { id = "r1", name = "role" } },
	},
})
local users = picked:selectedUsers()
h.equals("selectedUsers count skips roles", #users, 2)
h.equals("selectedUsers keeps pick order", users[1].username, "two")
h.equals("selectedUsers second", users[2].username, "one")
local members = picked:selectedMembers()
h.equals("selectedMembers count", #members, 2)
h.equals("selectedMembers keeps pick order", members[1].joined_at, "2021")
h.equals("selectedMembers splices user", (h.some(members[1].user)).id, "u2")
local roles = picked:selectedRoles()
h.equals("selectedRoles", #roles, 1)
h.equals("selectedRoles resolves", roles[1].name, "role")

local channelPick = makeIx((stubClient()), Const.InteractionType.MESSAGE_COMPONENT, {
	custom_id = "chan",
	values = { "c2", "c1" },
	resolved = { channels = { c1 = { id = "c1", type = 0 }, c2 = { id = "c2", type = 2 } } },
})
local channels = channelPick:selectedChannels()
h.equals("selectedChannels count", #channels, 2)
h.equals("selectedChannels keeps pick order", channels[1].id, "c2")
h.equals("no resolved data is an empty list", #channelPick:selectedUsers(), 0)

----------------------------------------------------------------------------
-- 4. Typo-checked builder specs
----------------------------------------------------------------------------

-- The specs are cast because the typos are exactly what the types reject
-- -- when the caller types them. Untyped (or `any`) callers are who this
-- catches at runtime.
local function spec(value: any): any
	return value
end

h.throws("button custom_id", 'button has no option "custom_id"; did you mean "id"?', function()
	Components.button(spec({ custom_id = "x", label = "X" }))
end)
h.throws("button sku_id", 'did you mean "sku"?', function()
	Components.button(spec({ sku_id = "1" }))
end)
h.throws("button typo by distance", 'did you mean "label"?', function()
	Components.button(spec({ id = "x", lable = "X" }))
end)
h.throws("builder typo blames the caller", "dx.test.luau", function()
	Components.button(spec({ custom_id = "x", label = "X" }))
end)
h.throws("select min_values", 'string select has no option "min_values"; did you mean "min"?', function()
	Components.select(spec({ id = "s", min_values = 1, options = { { label = "a", value = "a" } } }))
end)
h.throws("select misspelt options is the typo, not 'needs options'", 'did you mean "options"?', function()
	Components.select(spec({ id = "s", option = { { label = "a", value = "a" } } }))
end)
h.throws("select option typo", 'select option has no option "descripton"', function()
	Components.select(spec({ id = "s", options = { { label = "a", value = "a", descripton = "d" } } }))
end)
h.throws("user select max_values", 'user select has no option "max_values"; did you mean "max"?', function()
	Components.userSelect(spec({ id = "s", max_values = 2 }))
end)
h.throws("role select default_values", 'did you mean "defaults"?', function()
	Components.roleSelect(spec({ id = "s", default_values = { "1" } }))
end)
h.throws("mentionable select custom_id", 'mentionable select has no option "custom_id"', function()
	Components.mentionableSelect(spec({ custom_id = "s" }))
end)
h.throws("channel select channel_types", 'did you mean "channelTypes"?', function()
	Components.channelSelect(spec({ id = "s", channel_types = { 0 } }))
end)
h.throws("text input min_length", 'text input has no option "min_length"; did you mean "min"?', function()
	Components.textInput(spec({ id = "t", min_length = 1 }))
end)
h.throws("text input max_length", 'did you mean "max"?', function()
	Components.textInput(spec({ id = "t", max_length = 1 }))
end)
h.throws("section typo", 'section has no option "accesory"', function()
	Components.section(spec({ accesory = Components.button({ id = "b", label = "B" }) }), "text")
end)
h.throws("container accent_color", 'container has no option "accent_color"; did you mean "accent"?', function()
	Components.container(spec({ accent_color = 0xff0000 }), "text")
end)
h.throws("container color", 'did you mean "accent"?', function()
	Components.container(spec({ color = 0xff0000 }), "text")
end)
h.throws("thumbnail alt", 'thumbnail has no option "alt"; did you mean "description"?', function()
	Components.thumbnail("https://x/y.png", spec({ alt = "a picture" }))
end)
h.throws("gallery item typo", 'gallery item has no option "spolier"', function()
	Components.gallery(spec({ url = "https://x/y.png", spolier = true }))
end)
h.throws("file options typo", 'file has no option "spoilers"', function()
	Components.file("attachment://a.txt", spec({ spoilers = true }))
end)
h.throws("separator typo", 'separator has no option "spacng"; did you mean "spacing"?', function()
	Components.separator(spec({ spacng = "large" }))
end)
h.throws("file upload file_types", 'did you mean "types"?', function()
	Components.fileUpload(spec({ id = "f", file_types = { "image" } }))
end)
h.throws("radio group custom_id", 'radio group has no option "custom_id"; did you mean "id"?', function()
	Components.radioGroup(spec({ custom_id = "r", options = {} }))
end)
h.throws("radio option has no emoji", 'radio group option has no option "emoji"', function()
	Components.radioGroup(spec({
		id = "r",
		options = { { label = "a", value = "a", emoji = "x" }, { label = "b", value = "b" } },
	}))
end)
h.throws("checkbox group max_values", 'checkbox group has no option "max_values"; did you mean "max"?', function()
	Components.checkboxGroup(spec({ id = "g", options = { { label = "a", value = "a" } }, max_values = 1 }))
end)
h.throws("checkbox typo", 'checkbox has no option "defualt"; did you mean "default"?', function()
	Components.checkbox(spec({ id = "c", defualt = true }))
end)
h.throws("modal custom_id", 'modal has no option "custom_id"; did you mean "id"?', function()
	Components.modal(spec({ custom_id = "m", title = "T", components = {} }))
end)
-- Correct specs still build.
h.equals("a correct button builds", Components.button({ id = "ok", label = "OK" }).custom_id, "ok")
h.equals(
	"a correct select builds",
	Components.channelSelect({ id = "c", channelTypes = { 0 }, min = 1, max = 2 }).max_values,
	2
)

h.throws("collector options typo", 'collector has no option "messageID"; did you mean "messageId"?', function()
	Collector.new({ _collectors = {} } :: any, spec({ messageID = "m", timeout = 0 }))
end)
h.throws("collector wire-style name", 'did you mean "userId"?', function()
	Collector.new({ _collectors = {} } :: any, spec({ user_id = "u", timeout = 0 }))
end)
h.throws("paginator options typo", 'paginator has no option "timout"; did you mean "timeout"?', function()
	Paginator.reply({} :: any, {} :: any, spec({ pages = { "a" }, timout = 5 }))
end)

----------------------------------------------------------------------------
-- 5. Collector manners
----------------------------------------------------------------------------

-- Captures warnings. `Log.warn` is looked up at each call, so swapping the
-- field is enough.
local warnings: { string } = {}
local realWarn = Log.warn
Log.warn = function(message: string)
	table.insert(warnings, message)
end

local function host(): any
	return { _collectors = {} }
end

local function click(client: any, messageId: string, userId: string, customId: string): Interaction.Interaction
	return makeIx(client, Const.InteractionType.MESSAGE_COMPONENT, { custom_id = customId }, userId, messageId)
end

local function isEphemeral(body: any): boolean
	return type(body) == "table" and bit32.btest(body.flags or 0, Const.MessageFlag.EPHEMERAL)
end

-- Someone else's click on the owner's message.
local owned = Collector.new(host(), { messageId = "m1", userId = "owner", timeout = 0 })
h.equals("a scoped collector does not warn", #warnings, 0)
local strangerClient, strangerCalls = stubClient()
h.check("another user's click is consumed", owned:push(click(strangerClient, "m1", "stranger", "b")))
h.check("and is not collected", #owned.collected == 0)
h.check("they get a reply", Fakes.waitUntil(function(): boolean
	return #strangerCalls > 0
end))
h.equals("the reply is a message response", strangerCalls[1].kind, Const.InteractionCallback.CHANNEL_MESSAGE_WITH_SOURCE)
h.check("the reply is ephemeral", isEphemeral(strangerCalls[1].body))
h.equals("the default text", strangerCalls[1].body.content, "These buttons aren't for you.")
h.check("the owner's click still collects", owned:push(click((stubClient()), "m1", "owner", "b")))
h.check("a stranger on another message falls through", not owned:push(click((stubClient()), "m2", "stranger", "b")))

local customClient, customCalls = stubClient()
local custom = Collector.new(host(), { messageId = "m1", userId = "owner", timeout = 0, othersMessage = "Hands off." })
custom:push(click(customClient, "m1", "stranger", "b"))
Fakes.waitUntil(function(): boolean
	return #customCalls > 0
end)
h.equals("a custom othersMessage", customCalls[1] and customCalls[1].body.content, "Hands off.")

local silentClient, silentCalls = stubClient()
local silent = Collector.new(host(), { messageId = "m1", userId = "owner", timeout = 0, othersMessage = false })
h.check("othersMessage = false falls through", not silent:push(click(silentClient, "m1", "stranger", "b")))
task.wait(0.02)
h.equals("and sends nothing", #silentCalls, 0)

-- A filter that would reject the click anyway means it is not ours to refuse.
local filtered = Collector.new(host(), {
	messageId = "m1",
	userId = "owner",
	timeout = 0,
	filter = function(event: Interaction.Interaction): boolean
		return event.data.custom_id == "mine"
	end,
})
local otherButtonClient, otherButtonCalls = stubClient()
h.check("a stranger's click the filter rejects falls through", not filtered:push(click(otherButtonClient, "m1", "stranger", "theirs")))
task.wait(0.02)
h.equals("with no reply", #otherButtonCalls, 0)
h.check("a stranger's click the filter accepts is refused", filtered:push(click((stubClient()), "m1", "stranger", "mine")))

-- A throwing onCollect still answers the click.
local realError = Log.error
Log.error = function(_message: string) end
local throwClient, throwCalls = stubClient()
local throwing = Collector.new(host(), {
	messageId = "m1",
	timeout = 0,
	onCollect = function()
		error("handler blew up")
	end,
})
throwing:push(click(throwClient, "m1", "u1", "b"))
h.check("a throwing onCollect gets a reply", Fakes.waitUntil(function(): boolean
	return #throwCalls > 0
end))
h.check("the apology is ephemeral", throwCalls[1] ~= nil and isEphemeral(throwCalls[1].body))
h.equals("the apology text", throwCalls[1] and throwCalls[1].body.content, "Something went wrong handling that.")

local deferClient, deferCalls = stubClient()
local deferring = Collector.new(host(), {
	messageId = "m1",
	timeout = 0,
	onCollect = function(event: Interaction.Interaction)
		event:defer(true)
		error("after defer")
	end,
})
deferring:push(click(deferClient, "m1", "u1", "b"))
Fakes.waitUntil(function(): boolean
	return #deferCalls >= 2
end)
h.equals("a deferred failure edits the placeholder", deferCalls[2] and deferCalls[2].kind, -1)

local answeredClient, answeredCalls = stubClient()
local answered = Collector.new(host(), {
	messageId = "m1",
	timeout = 0,
	onCollect = function(event: Interaction.Interaction)
		event:update({ content = "done" })
		error("after update")
	end,
})
answered:push(click(answeredClient, "m1", "u1", "b"))
Fakes.waitUntil(function(): boolean
	return #answeredCalls >= 2
end)
h.equals("an answered failure follows up", answeredCalls[2] and answeredCalls[2].kind, -2)
Log.error = realError

-- The unscoped warning.
table.clear(warnings)
Collector.new(host(), { timeout = 0 })
h.equals("an unscoped collector warns once", #warnings, 1)
h.check("the warning names the fix", string.find(warnings[1] or "", "messageId", 1, true) ~= nil)
table.clear(warnings)
Collector.new(host(), { userId = "u", timeout = 0 })
h.check("a user-only collector still warns", string.find(warnings[1] or "", "from its user", 1, true) ~= nil)
table.clear(warnings)
Collector.new(host(), {
	timeout = 0,
	filter = function(): boolean
		return true
	end,
})
h.equals("a filtered collector does not warn", #warnings, 0)
Log.warn = realWarn

----------------------------------------------------------------------------
-- 6. Paginator pages straight from builder chains
----------------------------------------------------------------------------

-- Type-level: the inline builder chain into a typed array.
local pages: { Paginator.Page } = {}
table.insert(pages, Embed.new():setTitle("one"))
table.insert(pages, Embed.new():setTitle("two"):setDescription("body"))
table.insert(pages, "three")
h.equals("builder pages collect", #pages, 3)

local pageClient, pageCalls = stubClient()
local single = Paginator.reply(
	pageClient,
	makeIx(pageClient, Const.InteractionType.APPLICATION_COMMAND, { name = "p" }),
	{ pages = { Embed.new():setTitle("only") } }
)
h.equals("a one-page paginator has no collector", single, nil)
local sentEmbeds = pageCalls[1] and pageCalls[1].body.embeds
h.equals("a builder page is sent as an embed", sentEmbeds and sentEmbeds[1].title, "only")

----------------------------------------------------------------------------
-- 7. Bitfields accept permission names
----------------------------------------------------------------------------

local perms = Bitfield.of("kickMembers", "banMembers")
h.check("has by name", perms:has("banMembers"))
h.check("lacks by name", not perms:has("administrator"))
h.check("hasAny by name", perms:hasAny("kickMembers"))
h.check("without by name", not perms:without("banMembers"):has("banMembers"))
h.equals("fromName is the bit", Bitfield.fromName("banMembers"):toString(), "4")
h.check("digits are still a mask", Bitfield.coerce("4"):has("banMembers"))
h.equals("empty string is still zero", Bitfield.coerce(""):toString(), "0")
h.throws("misspelt name", 'unknown permission "banMemebrs"; did you mean "banMembers"?', function()
	perms:has("banMemebrs")
end)
h.throws("screaming case suggests camel", 'did you mean "banMembers"?', function()
	perms:has("BAN_MEMBERS")
end)
h.throws("hopeless name has no suggestion", 'unknown permission "xyzzy"', function()
	perms:has("xyzzy")
end)
h.throws("bitfield typo blames the caller", "dx.test.luau", function()
	perms:has("banMemebrs")
end)
h.throws("Permissions.of suggests too", 'did you mean "kickMembers"?', function()
	Permissions.of("kickMember")
end)

----------------------------------------------------------------------------
-- 8. Permission checks on members without `user`
----------------------------------------------------------------------------

local VIEW = Bitfield.fromBit(Const.PermissionBits.viewChannel)
local SEND = Bitfield.fromBit(Const.PermissionBits.sendMessages)
local guild: any = {
	id = "g",
	name = "guild",
	owner_id = "owner",
	roles = {
		{ id = "g", name = "@everyone", position = 0, permissions = VIEW:toString() },
		{ id = "mod", name = "mod", position = 5, permissions = SEND:toString() },
	},
}
-- The shape `data.resolved.members` has: no `user`.
local bareOwner: any = { roles = {}, joined_at = "" }
local bareMod: any = { roles = { "mod" }, joined_at = "" }

warnings = {}
Log.warn = function(message: string)
	table.insert(warnings, message)
end
h.check("owner recognised by userId", Permissions.forMember(guild, bareOwner, nil, "owner") == Permissions.ALL)
h.check("without an id the owner falls back to roles", Permissions.forMember(guild, bareOwner) ~= Permissions.ALL)
h.check("and that is warned about", #warnings == 1 and string.find(warnings[1], "userId", 1, true) ~= nil)
Permissions.forMember(guild, bareOwner)
h.equals("the warning is only given once", #warnings, 1)
Log.warn = realWarn

local channel: any = {
	id = "ch",
	type = 0,
	permission_overwrites = {
		{ id = "someone", type = Const.OverwriteType.MEMBER, allow = SEND:toString(), deny = "0" },
	},
}
h.check("forChannel finds the member overwrite by userId", Permissions.forChannel(guild, bareOwner :: any, channel, nil, "someone"):has(SEND))
h.check("forChannel owner by userId", Permissions.forChannel(guild, bareOwner, channel, nil, "owner") == Permissions.ALL)
h.check("outranks: owner actor by id", Permissions.outranks(guild, bareOwner, bareMod, nil, "owner", "m"))
h.check("outranks: owner target by id", not Permissions.outranks(guild, bareMod, bareOwner, nil, "m", "owner"))
h.check(
	"members with user still work unchanged",
	Permissions.forMember(guild, { user = { id = "owner", username = "o" }, roles = {}, joined_at = "" } :: any)
		== Permissions.ALL
)

h.finish()
