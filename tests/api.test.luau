--!strict
-- The endpoint layer, driven through a fake transport: every route's method,
-- path and query string, which routes carry auth and audit reasons, the two
-- multipart shapes, and the CDN URL builders (which make no requests).
local Api = require("@discord/api")
local Http = require("@discord/http")
local Json = require("@discord/json")
local Util = require("@discord/util")
local h = require("./harness")

local BASE = "https://api.test"

type Call = {
	url: string,
	method: string,
	path: string,
	body: string?,
	headers: { [string]: string },
}

local calls: { Call } = {}
local queue: { { status: number, body: string } } = {}

local function fake(url: string, request: Http.TransportRequest): Http.TransportResponse
	table.insert(calls, {
		url = url,
		method = request.method,
		path = string.sub(url, #BASE + 1),
		body = request.body,
		headers = request.headers,
	})
	local canned = table.remove(queue, 1) or { status = 200, body = "{}" }
	return { status = canned.status, headers = {}, body = canned.body }
end

local api = Api.new(Http.new("tkn", { transport = fake, baseUrl = BASE }))

local function last(): Call
	return calls[#calls]
end

local function respond(status: number, body: string)
	table.insert(queue, { status = status, body = body })
end

local function png(name: string): Http.File
	return { name = name, data = "\137PNG-bytes", contentType = "image/png" }
end

local ID = "111111111111111111"
local ID2 = "222222222222222222"
local ID3 = "333333333333333333"

----------------------------------------------------------------------------
-- Every route added in this pass, table-driven: method, path + query, auth.
----------------------------------------------------------------------------

type Route = { name: string, run: () -> (), method: string, path: string, noAuth: boolean? }

local routes: { Route } = {
	-- Channels
	{
		name = "channels.getReactions burst",
		run = function()
			api.channels.getReactions(ID, ID2, "\u{1F525}", { type = 1, limit = 5 })
		end,
		method = "GET",
		path = `/channels/{ID}/messages/{ID2}/reactions/%F0%9F%94%A5?limit=5&type=1`,
	},
	{
		name = "channels.getPins",
		run = function()
			api.channels.getPins(ID, { before = "2026-01-01T00:00:00Z", limit = 50 })
		end,
		method = "GET",
		path = `/channels/{ID}/messages/pins?before=2026-01-01T00%3A00%3A00Z&limit=50`,
	},
	{
		name = "channels.pinMessage uses the new route",
		run = function()
			api.channels.pinMessage(ID, ID2)
		end,
		method = "PUT",
		path = `/channels/{ID}/messages/pins/{ID2}`,
	},
	{
		name = "channels.unpinMessage uses the new route",
		run = function()
			api.channels.unpinMessage(ID, ID2)
		end,
		method = "DELETE",
		path = `/channels/{ID}/messages/pins/{ID2}`,
	},
	{
		name = "channels.getPinnedMessages keeps the old route",
		run = function()
			api.channels.getPinnedMessages(ID)
		end,
		method = "GET",
		path = `/channels/{ID}/pins`,
	},
	{
		name = "channels.setVoiceStatus",
		run = function()
			api.channels.setVoiceStatus(ID, "jamming")
		end,
		method = "PUT",
		path = `/channels/{ID}/voice-status`,
	},
	{
		name = "channels.leaveThread",
		run = function()
			api.channels.leaveThread(ID)
		end,
		method = "DELETE",
		path = `/channels/{ID}/thread-members/@me`,
	},
	{
		name = "channels.getThreadMember",
		run = function()
			api.channels.getThreadMember(ID, ID2, true)
		end,
		method = "GET",
		path = `/channels/{ID}/thread-members/{ID2}?with_member=true`,
	},
	{
		name = "channels.listThreadMembers paginated",
		run = function()
			api.channels.listThreadMembers(ID, { with_member = true, after = ID2, limit = 50 })
		end,
		method = "GET",
		path = `/channels/{ID}/thread-members?after={ID2}&limit=50&with_member=true`,
	},
	{
		name = "channels.listPublicArchivedThreads",
		run = function()
			api.channels.listPublicArchivedThreads(ID, { limit = 10 })
		end,
		method = "GET",
		path = `/channels/{ID}/threads/archived/public?limit=10`,
	},
	{
		name = "channels.listPrivateArchivedThreads",
		run = function()
			api.channels.listPrivateArchivedThreads(ID)
		end,
		method = "GET",
		path = `/channels/{ID}/threads/archived/private`,
	},
	{
		name = "channels.listJoinedPrivateArchivedThreads",
		run = function()
			api.channels.listJoinedPrivateArchivedThreads(ID, { before = ID2 })
		end,
		method = "GET",
		path = `/channels/{ID}/users/@me/threads/archived/private?before={ID2}`,
	},
	{
		name = "channels.followAnnouncementChannel",
		run = function()
			api.channels.followAnnouncementChannel(ID, ID2, "mirror")
		end,
		method = "POST",
		path = `/channels/{ID}/followers`,
	},

	-- Guilds
	{
		name = "guilds.getPreview",
		run = function()
			api.guilds.getPreview(ID)
		end,
		method = "GET",
		path = `/guilds/{ID}/preview`,
	},
	{
		name = "guilds.addMember",
		run = function()
			api.guilds.addMember(ID, ID2, { access_token = "user-oauth" })
		end,
		method = "PUT",
		path = `/guilds/{ID}/members/{ID2}`,
	},
	{
		name = "guilds.bulkBan",
		run = function()
			api.guilds.bulkBan(ID, { ID2, ID3 }, { deleteMessageSeconds = 60 })
		end,
		method = "POST",
		path = `/guilds/{ID}/bulk-ban`,
	},
	{
		name = "guilds.getRole",
		run = function()
			api.guilds.getRole(ID, ID2)
		end,
		method = "GET",
		path = `/guilds/{ID}/roles/{ID2}`,
	},
	{
		name = "guilds.getRoleMemberCounts",
		run = function()
			api.guilds.getRoleMemberCounts(ID)
		end,
		method = "GET",
		path = `/guilds/{ID}/roles/member-counts`,
	},
	{
		name = "guilds.getVoiceRegions",
		run = function()
			api.guilds.getVoiceRegions(ID)
		end,
		method = "GET",
		path = `/guilds/{ID}/regions`,
	},
	{
		name = "guilds.getIntegrations",
		run = function()
			api.guilds.getIntegrations(ID)
		end,
		method = "GET",
		path = `/guilds/{ID}/integrations`,
	},
	{
		name = "guilds.deleteIntegration",
		run = function()
			api.guilds.deleteIntegration(ID, ID2)
		end,
		method = "DELETE",
		path = `/guilds/{ID}/integrations/{ID2}`,
	},
	{
		name = "guilds.getEmoji",
		run = function()
			api.guilds.getEmoji(ID, ID2)
		end,
		method = "GET",
		path = `/guilds/{ID}/emojis/{ID2}`,
	},
	{
		name = "guilds.editEmoji",
		run = function()
			api.guilds.editEmoji(ID, ID2, { name = "blob" })
		end,
		method = "PATCH",
		path = `/guilds/{ID}/emojis/{ID2}`,
	},
	{
		name = "guilds.getScheduledEvent",
		run = function()
			api.guilds.getScheduledEvent(ID, ID2, true)
		end,
		method = "GET",
		path = `/guilds/{ID}/scheduled-events/{ID2}?with_user_count=true`,
	},
	{
		name = "guilds.getScheduledEventUsers",
		run = function()
			api.guilds.getScheduledEventUsers(ID, ID2, { limit = 100, with_member = true })
		end,
		method = "GET",
		path = `/guilds/{ID}/scheduled-events/{ID2}/users?limit=100&with_member=true`,
	},
	{
		name = "guilds.getWidgetSettings",
		run = function()
			api.guilds.getWidgetSettings(ID)
		end,
		method = "GET",
		path = `/guilds/{ID}/widget`,
	},
	{
		name = "guilds.editWidget",
		run = function()
			api.guilds.editWidget(ID, { enabled = true })
		end,
		method = "PATCH",
		path = `/guilds/{ID}/widget`,
	},
	{
		name = "guilds.getWelcomeScreen",
		run = function()
			api.guilds.getWelcomeScreen(ID)
		end,
		method = "GET",
		path = `/guilds/{ID}/welcome-screen`,
	},
	{
		name = "guilds.editWelcomeScreen",
		run = function()
			api.guilds.editWelcomeScreen(ID, { enabled = false })
		end,
		method = "PATCH",
		path = `/guilds/{ID}/welcome-screen`,
	},
	{
		name = "guilds.editOnboarding",
		run = function()
			api.guilds.editOnboarding(ID, { enabled = false })
		end,
		method = "PUT",
		path = `/guilds/{ID}/onboarding`,
	},
	{
		name = "guilds.editIncidentActions",
		run = function()
			api.guilds.editIncidentActions(ID, { invites_disabled_until = "2026-09-27T00:00:00Z" })
		end,
		method = "PUT",
		path = `/guilds/{ID}/incident-actions`,
	},
	{
		name = "guilds.searchMessages repeats array keys",
		run = function()
			api.guilds.searchMessages(ID, { content = "hi there", channel_id = { ID2, ID3 }, pinned = true })
		end,
		method = "GET",
		path = `/guilds/{ID}/messages/search?channel_id={ID2}&channel_id={ID3}&content=hi%20there&pinned=true`,
	},
	{
		name = "guilds.getTemplate",
		run = function()
			api.guilds.getTemplate("hgM48av5Q69A")
		end,
		method = "GET",
		path = "/guilds/templates/hgM48av5Q69A",
	},
	{
		name = "guilds.getTemplates",
		run = function()
			api.guilds.getTemplates(ID)
		end,
		method = "GET",
		path = `/guilds/{ID}/templates`,
	},
	{
		name = "guilds.createTemplate",
		run = function()
			api.guilds.createTemplate(ID, { name = "base" })
		end,
		method = "POST",
		path = `/guilds/{ID}/templates`,
	},
	{
		name = "guilds.syncTemplate",
		run = function()
			api.guilds.syncTemplate(ID, "code1")
		end,
		method = "PUT",
		path = `/guilds/{ID}/templates/code1`,
	},
	{
		name = "guilds.editTemplate",
		run = function()
			api.guilds.editTemplate(ID, "code1", { name = "renamed" })
		end,
		method = "PATCH",
		path = `/guilds/{ID}/templates/code1`,
	},
	{
		name = "guilds.deleteTemplate",
		run = function()
			api.guilds.deleteTemplate(ID, "code1")
		end,
		method = "DELETE",
		path = `/guilds/{ID}/templates/code1`,
	},

	-- Stickers
	{
		name = "stickers.get",
		run = function()
			api.stickers.get(ID)
		end,
		method = "GET",
		path = `/stickers/{ID}`,
	},
	{
		name = "stickers.listPacks",
		run = function()
			api.stickers.listPacks()
		end,
		method = "GET",
		path = "/sticker-packs",
	},
	{
		name = "stickers.getPack",
		run = function()
			api.stickers.getPack(ID)
		end,
		method = "GET",
		path = `/sticker-packs/{ID}`,
	},
	{
		name = "stickers.list",
		run = function()
			api.stickers.list(ID)
		end,
		method = "GET",
		path = `/guilds/{ID}/stickers`,
	},
	{
		name = "stickers.getGuildSticker",
		run = function()
			api.stickers.getGuildSticker(ID, ID2)
		end,
		method = "GET",
		path = `/guilds/{ID}/stickers/{ID2}`,
	},
	{
		name = "stickers.create",
		run = function()
			api.stickers.create(ID, { name = "wave", tags = "wave", file = png("wave.png") })
		end,
		method = "POST",
		path = `/guilds/{ID}/stickers`,
	},
	{
		name = "stickers.edit",
		run = function()
			api.stickers.edit(ID, ID2, { name = "wave2" })
		end,
		method = "PATCH",
		path = `/guilds/{ID}/stickers/{ID2}`,
	},
	{
		name = "stickers.delete",
		run = function()
			api.stickers.delete(ID, ID2)
		end,
		method = "DELETE",
		path = `/guilds/{ID}/stickers/{ID2}`,
	},

	-- Soundboard
	{
		name = "soundboard.send",
		run = function()
			api.soundboard.send(ID, ID2, ID3)
		end,
		method = "POST",
		path = `/channels/{ID}/send-soundboard-sound`,
	},
	{
		name = "soundboard.listDefault",
		run = function()
			api.soundboard.listDefault()
		end,
		method = "GET",
		path = "/soundboard-default-sounds",
	},
	{
		name = "soundboard.list",
		run = function()
			api.soundboard.list(ID)
		end,
		method = "GET",
		path = `/guilds/{ID}/soundboard-sounds`,
	},
	{
		name = "soundboard.get",
		run = function()
			api.soundboard.get(ID, ID2)
		end,
		method = "GET",
		path = `/guilds/{ID}/soundboard-sounds/{ID2}`,
	},
	{
		name = "soundboard.create",
		run = function()
			api.soundboard.create(ID, { name = "honk", sound = "data:audio/ogg;base64,AA==" })
		end,
		method = "POST",
		path = `/guilds/{ID}/soundboard-sounds`,
	},
	{
		name = "soundboard.edit",
		run = function()
			api.soundboard.edit(ID, ID2, { volume = 0.5 })
		end,
		method = "PATCH",
		path = `/guilds/{ID}/soundboard-sounds/{ID2}`,
	},
	{
		name = "soundboard.delete",
		run = function()
			api.soundboard.delete(ID, ID2)
		end,
		method = "DELETE",
		path = `/guilds/{ID}/soundboard-sounds/{ID2}`,
	},

	-- Stage instances
	{
		name = "stageInstances.create",
		run = function()
			api.stageInstances.create({ channel_id = ID, topic = "town hall" })
		end,
		method = "POST",
		path = "/stage-instances",
	},
	{
		name = "stageInstances.get",
		run = function()
			api.stageInstances.get(ID)
		end,
		method = "GET",
		path = `/stage-instances/{ID}`,
	},
	{
		name = "stageInstances.edit",
		run = function()
			api.stageInstances.edit(ID, { topic = "q&a" })
		end,
		method = "PATCH",
		path = `/stage-instances/{ID}`,
	},
	{
		name = "stageInstances.delete",
		run = function()
			api.stageInstances.delete(ID)
		end,
		method = "DELETE",
		path = `/stage-instances/{ID}`,
	},

	-- Voice
	{
		name = "voice.listRegions",
		run = function()
			api.voice.listRegions()
		end,
		method = "GET",
		path = "/voice/regions",
	},
	{
		name = "voice.getCurrentState",
		run = function()
			api.voice.getCurrentState(ID)
		end,
		method = "GET",
		path = `/guilds/{ID}/voice-states/@me`,
	},
	{
		name = "voice.getUserState",
		run = function()
			api.voice.getUserState(ID, ID2)
		end,
		method = "GET",
		path = `/guilds/{ID}/voice-states/{ID2}`,
	},
	{
		name = "voice.editCurrentState",
		run = function()
			api.voice.editCurrentState(ID, { channel_id = ID2, suppress = false })
		end,
		method = "PATCH",
		path = `/guilds/{ID}/voice-states/@me`,
	},
	{
		name = "voice.editUserState",
		run = function()
			api.voice.editUserState(ID, ID2, { channel_id = ID3, suppress = true })
		end,
		method = "PATCH",
		path = `/guilds/{ID}/voice-states/{ID2}`,
	},

	-- Users
	{
		name = "users.getGuilds with shard",
		run = function()
			api.users.getGuilds({ shard = 2, before = ID })
		end,
		method = "GET",
		path = `/users/@me/guilds?before={ID}&shard=2`,
	},

	-- Applications
	{
		name = "applications.getGlobalCommand",
		run = function()
			api.applications.getGlobalCommand(ID, ID2)
		end,
		method = "GET",
		path = `/applications/{ID}/commands/{ID2}`,
	},
	{
		name = "applications.editGlobalCommand",
		run = function()
			api.applications.editGlobalCommand(ID, ID2, { description = "new" })
		end,
		method = "PATCH",
		path = `/applications/{ID}/commands/{ID2}`,
	},
	{
		name = "applications.getGuildCommands with localizations",
		run = function()
			api.applications.getGuildCommands(ID, ID2, true)
		end,
		method = "GET",
		path = `/applications/{ID}/guilds/{ID2}/commands?with_localizations=true`,
	},
	{
		name = "applications.getGuildCommand",
		run = function()
			api.applications.getGuildCommand(ID, ID2, ID3)
		end,
		method = "GET",
		path = `/applications/{ID}/guilds/{ID2}/commands/{ID3}`,
	},
	{
		name = "applications.editGuildCommand",
		run = function()
			api.applications.editGuildCommand(ID, ID2, ID3, { nsfw = true })
		end,
		method = "PATCH",
		path = `/applications/{ID}/guilds/{ID2}/commands/{ID3}`,
	},
	{
		name = "applications.getGuildCommandPermissions",
		run = function()
			api.applications.getGuildCommandPermissions(ID, ID2)
		end,
		method = "GET",
		path = `/applications/{ID}/guilds/{ID2}/commands/permissions`,
	},
	{
		name = "applications.getCommandPermissions",
		run = function()
			api.applications.getCommandPermissions(ID, ID2, ID3)
		end,
		method = "GET",
		path = `/applications/{ID}/guilds/{ID2}/commands/{ID3}/permissions`,
	},
	{
		name = "applications.getEmoji",
		run = function()
			api.applications.getEmoji(ID, ID2)
		end,
		method = "GET",
		path = `/applications/{ID}/emojis/{ID2}`,
	},
	{
		name = "applications.createEmoji",
		run = function()
			api.applications.createEmoji(ID, "blob", "data:image/png;base64,AA==")
		end,
		method = "POST",
		path = `/applications/{ID}/emojis`,
	},
	{
		name = "applications.editEmoji",
		run = function()
			api.applications.editEmoji(ID, ID2, "blob2")
		end,
		method = "PATCH",
		path = `/applications/{ID}/emojis/{ID2}`,
	},
	{
		name = "applications.deleteEmoji",
		run = function()
			api.applications.deleteEmoji(ID, ID2)
		end,
		method = "DELETE",
		path = `/applications/{ID}/emojis/{ID2}`,
	},
	{
		name = "applications.getRoleConnectionMetadata",
		run = function()
			api.applications.getRoleConnectionMetadata(ID)
		end,
		method = "GET",
		path = `/applications/{ID}/role-connections/metadata`,
	},
	{
		name = "applications.updateRoleConnectionMetadata",
		run = function()
			api.applications.updateRoleConnectionMetadata(ID, {
				{ type = 7, key = "verified", name = "Verified", description = "Linked an account" },
			})
		end,
		method = "PUT",
		path = `/applications/{ID}/role-connections/metadata`,
	},
	{
		name = "applications.getActivityInstance",
		run = function()
			api.applications.getActivityInstance(ID, "i-123/x")
		end,
		method = "GET",
		path = `/applications/{ID}/activity-instances/i-123%2Fx`,
	},

	-- Monetization
	{
		name = "monetization.listSkus",
		run = function()
			api.monetization.listSkus(ID)
		end,
		method = "GET",
		path = `/applications/{ID}/skus`,
	},
	{
		name = "monetization.listEntitlements joins sku_ids with commas",
		run = function()
			api.monetization.listEntitlements(ID, { sku_ids = { ID2, ID3 }, exclude_ended = true })
		end,
		method = "GET",
		path = `/applications/{ID}/entitlements?exclude_ended=true&sku_ids={ID2}%2C{ID3}`,
	},
	{
		name = "monetization.getEntitlement",
		run = function()
			api.monetization.getEntitlement(ID, ID2)
		end,
		method = "GET",
		path = `/applications/{ID}/entitlements/{ID2}`,
	},
	{
		name = "monetization.consumeEntitlement",
		run = function()
			api.monetization.consumeEntitlement(ID, ID2)
		end,
		method = "POST",
		path = `/applications/{ID}/entitlements/{ID2}/consume`,
	},
	{
		name = "monetization.createTestEntitlement",
		run = function()
			api.monetization.createTestEntitlement(ID, { sku_id = ID2, owner_id = ID3, owner_type = 2 })
		end,
		method = "POST",
		path = `/applications/{ID}/entitlements`,
	},
	{
		name = "monetization.deleteTestEntitlement",
		run = function()
			api.monetization.deleteTestEntitlement(ID, ID2)
		end,
		method = "DELETE",
		path = `/applications/{ID}/entitlements/{ID2}`,
	},
	{
		name = "monetization.listSubscriptions",
		run = function()
			api.monetization.listSubscriptions(ID, ID2, { limit = 10 })
		end,
		method = "GET",
		path = `/skus/{ID}/subscriptions?limit=10&user_id={ID2}`,
	},
	{
		name = "monetization.getSubscription",
		run = function()
			api.monetization.getSubscription(ID, ID2)
		end,
		method = "GET",
		path = `/skus/{ID}/subscriptions/{ID2}`,
	},

	-- Interactions
	{
		name = "interactions.createResponseWithResult",
		run = function()
			api.interactions.createResponseWithResult(ID, "itoken", 4, { content = "hi" })
		end,
		method = "POST",
		path = `/interactions/{ID}/itoken/callback?with_response=true`,
		noAuth = true,
	},
	{
		name = "interactions.getFollowup",
		run = function()
			api.interactions.getFollowup(ID, "itoken", ID2)
		end,
		method = "GET",
		path = `/webhooks/{ID}/itoken/messages/{ID2}`,
		noAuth = true,
	},

	-- Webhooks
	{
		name = "webhooks.get",
		run = function()
			api.webhooks.get(ID)
		end,
		method = "GET",
		path = `/webhooks/{ID}`,
	},
	{
		name = "webhooks.getWithToken",
		run = function()
			api.webhooks.getWithToken(ID, "wtoken")
		end,
		method = "GET",
		path = `/webhooks/{ID}/wtoken`,
		noAuth = true,
	},
	{
		name = "webhooks.edit",
		run = function()
			api.webhooks.edit(ID, { name = "hook", channel_id = ID2 })
		end,
		method = "PATCH",
		path = `/webhooks/{ID}`,
	},
	{
		name = "webhooks.editWithToken",
		run = function()
			api.webhooks.editWithToken(ID, "wtoken", { name = "hook" })
		end,
		method = "PATCH",
		path = `/webhooks/{ID}/wtoken`,
		noAuth = true,
	},
	{
		name = "webhooks.deleteWithToken",
		run = function()
			api.webhooks.deleteWithToken(ID, "wtoken")
		end,
		method = "DELETE",
		path = `/webhooks/{ID}/wtoken`,
		noAuth = true,
	},
	{
		name = "webhooks.execute with_components",
		run = function()
			api.webhooks.execute(ID, "wtoken", "hi", { wait = true, with_components = true })
		end,
		method = "POST",
		path = `/webhooks/{ID}/wtoken?wait=true&with_components=true`,
		noAuth = true,
	},
	{
		name = "webhooks.getMessage in a thread",
		run = function()
			api.webhooks.getMessage(ID, "wtoken", ID2, ID3)
		end,
		method = "GET",
		path = `/webhooks/{ID}/wtoken/messages/{ID2}?thread_id={ID3}`,
		noAuth = true,
	},
	{
		name = "webhooks.editMessage",
		run = function()
			api.webhooks.editMessage(ID, "wtoken", ID2, "edited")
		end,
		method = "PATCH",
		path = `/webhooks/{ID}/wtoken/messages/{ID2}`,
		noAuth = true,
	},
	{
		name = "webhooks.deleteMessage",
		run = function()
			api.webhooks.deleteMessage(ID, "wtoken", ID2)
		end,
		method = "DELETE",
		path = `/webhooks/{ID}/wtoken/messages/{ID2}`,
		noAuth = true,
	},

	-- Invites
	{
		name = "invites.get with event",
		run = function()
			api.invites.get("abc#1", true, ID)
		end,
		method = "GET",
		path = `/invites/abc%231?guild_scheduled_event_id={ID}&with_counts=true`,
	},
	{
		name = "invites.addTargetUser",
		run = function()
			api.invites.addTargetUser("abc", ID)
		end,
		method = "PUT",
		path = `/invites/abc/target-users/{ID}`,
	},
	{
		name = "invites.removeTargetUser",
		run = function()
			api.invites.removeTargetUser("abc", ID)
		end,
		method = "DELETE",
		path = `/invites/abc/target-users/{ID}`,
	},
	{
		name = "invites.bulkAddTargetUsers",
		run = function()
			api.invites.bulkAddTargetUsers("abc", { ID, ID2 })
		end,
		method = "POST",
		path = "/invites/abc/target-users/bulk-add",
	},
	{
		name = "invites.bulkDeleteTargetUsers",
		run = function()
			api.invites.bulkDeleteTargetUsers("abc", { ID })
		end,
		method = "POST",
		path = "/invites/abc/target-users/bulk-delete",
	},
	{
		name = "invites.updateTargetUsers",
		run = function()
			api.invites.updateTargetUsers("abc", { name = "users.csv", data = `{ID}\n{ID2}\n`, contentType = "text/csv" })
		end,
		method = "PUT",
		path = "/invites/abc/target-users",
	},
	{
		name = "invites.getTargetUsersJobStatus",
		run = function()
			api.invites.getTargetUsersJobStatus("abc")
		end,
		method = "GET",
		path = "/invites/abc/target-users/job-status",
	},
}

for _, route in routes do
	local before = #calls
	local ok, err = pcall(route.run)
	if not ok then
		h.check(`{route.name} -- threw {tostring(err)}`, false)
		continue
	end
	local call = last()
	h.check(`{route.name}: one request`, #calls == before + 1)
	h.equals(`{route.name}: method`, call.method, route.method)
	h.equals(`{route.name}: path`, call.path, route.path)
	h.equals(
		`{route.name}: auth`,
		call.headers["Authorization"],
		if route.noAuth then nil else "Bot tkn"
	)
end

----------------------------------------------------------------------------
-- Bodies and headers
----------------------------------------------------------------------------

local function body(): any
	local raw = last().body
	return if raw ~= nil then (Json.decode(raw)) else nil
end

api.channels.followAnnouncementChannel(ID, ID2, "Spam & abuse\nline two \u{FC}")
h.equals(
	"audit reason is percent-encoded into the header",
	last().headers["X-Audit-Log-Reason"],
	"Spam%20%26%20abuse%0Aline%20two%20%C3%BC"
)
h.equals("follow body names the target", body().webhook_channel_id, ID2)

api.guilds.bulkBan(ID, { ID2 }, nil, "raid")
h.equals("bulk ban carries the reason", last().headers["X-Audit-Log-Reason"], "raid")
h.equals("bulk ban sends user_ids", body().user_ids[1], ID2)
h.equals("bulk ban omits an unset delete window", body().delete_message_seconds, nil)

api.channels.setVoiceStatus(ID, nil)
h.check("clearing a voice status sends an explicit null", string.find(last().body or "", '"status":%s*null') ~= nil)

api.guilds.getPreview(ID)
h.equals("GET without a reason sends no reason header", last().headers["X-Audit-Log-Reason"], nil)
h.equals("GET sends no body", last().body, nil)

api.soundboard.send(ID, ID2)
h.equals("soundboard send body", body().sound_id, ID2)
h.equals("soundboard send omits source guild when unset", body().source_guild_id, nil)

api.webhooks.edit(ID, { name = "renamed" }, "tidy")
h.equals("webhook edit carries the reason", last().headers["X-Audit-Log-Reason"], "tidy")

api.channels.createInvite(ID)
h.check("createInvite with no options sends {} not []", string.find(last().body or "", "^%s*{%s*}%s*$") ~= nil)
api.channels.createInvite(ID, { max_age = 60 })
h.equals("createInvite passes options through", body().max_age, 60)
api.guilds.banMember(ID, ID2)
h.equals("banMember with no options sends no body", last().body, nil)
api.guilds.banMember(ID, ID2, { deleteMessageSeconds = 3600 })
h.equals("banMember sends the delete window", body().delete_message_seconds, 3600)

----------------------------------------------------------------------------
-- Multipart: the two shapes
----------------------------------------------------------------------------

api.stickers.create(ID, { name = "wave", description = "hello", tags = "wave", file = png("wave.png") }, "new sticker")
do
	local call = last()
	local raw = call.body or ""
	h.check(
		"sticker create is multipart",
		string.sub(call.headers["Content-Type"] or "", 1, 19) == "multipart/form-data"
	)
	h.check("sticker create has a name field", string.find(raw, 'name="name"\r\n\r\nwave\r\n', 1, true) ~= nil)
	h.check("sticker create has a tags field", string.find(raw, 'name="tags"\r\n\r\nwave\r\n', 1, true) ~= nil)
	h.check("sticker create has a description field", string.find(raw, 'name="description"\r\n\r\nhello\r\n', 1, true) ~= nil)
	h.check("sticker file travels as the `file` part", string.find(raw, 'name="file"; filename="wave.png"', 1, true) ~= nil)
	h.check("sticker create sends no payload_json", string.find(raw, "payload_json", 1, true) == nil)
	h.equals("sticker create keeps its audit reason", call.headers["X-Audit-Log-Reason"], "new%20sticker")
end

api.stickers.create(ID, { name = "wave", tags = "wave", file = png("wave.png") })
h.check(
	"sticker description defaults to an empty field",
	string.find(last().body or "", 'name="description"\r\n\r\n\r\n', 1, true) ~= nil
)

api.invites.updateTargetUsers("abc", { name = "users.csv", data = "1\n", contentType = "text/csv" })
h.check(
	"target users CSV travels as target_users_file",
	string.find(last().body or "", 'name="target_users_file"; filename="users.csv"', 1, true) ~= nil
)

api.webhooks.editMessage(ID, "wtoken", ID2, { content = "with a file", files = { png("a.png") } }, { thread_id = ID3 })
do
	local call = last()
	local raw = call.body or ""
	h.equals("webhook message edit keeps thread_id", call.path, `/webhooks/{ID}/wtoken/messages/{ID2}?thread_id={ID3}`)
	h.check("webhook message edit with files is multipart", string.find(call.headers["Content-Type"] or "", "multipart", 1, true) ~= nil)
	h.check("webhook message edit sends payload_json", string.find(raw, 'name="payload_json"', 1, true) ~= nil)
	h.check("webhook message edit sends files[0]", string.find(raw, 'name="files[0]"; filename="a.png"', 1, true) ~= nil)
	h.check("webhook message edit is unauthenticated", call.headers["Authorization"] == nil)
end

api.webhooks.editMessage(ID, "wtoken", ID2, "rows", { with_components = true })
h.equals(
	"webhook message edit passes with_components",
	last().path,
	`/webhooks/{ID}/wtoken/messages/{ID2}?with_components=true`
)

----------------------------------------------------------------------------
-- with_response
----------------------------------------------------------------------------

respond(204, "")
api.interactions.createResponse(ID, "itoken", 5)
h.equals("createResponse sends no with_response", last().path, `/interactions/{ID}/itoken/callback`)
h.equals("createResponse is unauthenticated", last().headers["Authorization"], nil)

respond(200, `\{"interaction":\{"id":"{ID}","type":2,"response_message_id":"{ID3}"},"resource":\{"type":4,"message":\{"id":"{ID3}","content":"hi"}}}`)
local result = api.interactions.createResponseWithResult(ID, "itoken", 4, { content = "hi" })
h.equals("with_response returns the interaction", result.interaction.id, ID)
h.equals("with_response returns the created message", (result.resource :: any).message.id, ID3)
h.equals("with_response still sends the callback body", body().type, 4)

----------------------------------------------------------------------------
-- Search: the not-indexed-yet answer is a success, not an error
----------------------------------------------------------------------------

respond(202, `\{"message":"Index not yet available. Try again later","code":110000,"documents_indexed":0,"retry_after":2}`)
local search = api.guilds.searchMessages(ID, { content = "x" })
h.equals("unindexed search surfaces code 110000", search.code, 110000)
h.equals("unindexed search surfaces retry_after", search.retry_after, 2)

----------------------------------------------------------------------------
-- Array query strings (Util.query)
----------------------------------------------------------------------------

h.equals("array values repeat the key", Util.query({ id = { "1", "2" } }), "?id=1&id=2")
h.equals("scalars are unchanged", Util.query({ limit = 5, after = "9" }), "?after=9&limit=5")
h.equals("an empty array contributes nothing", Util.query({ id = {} :: { string } }), "")
h.equals("array elements are encoded", Util.query({ q = { "a b", "c&d" } }), "?q=a%20b&q=c%26d")

----------------------------------------------------------------------------
-- Argument validation: rejected before any request goes out
----------------------------------------------------------------------------

local function rejects(name: string, fragment: string, fn: () -> ())
	local before = #calls
	h.throws(name, fragment, fn)
	h.check(`{name}: nothing sent`, #calls == before)
end

local many: { string } = {}
for index = 1, 201 do
	many[index] = tostring(100000000000000000 + index)
end

rejects("bulk ban rejects an empty list", "1 to 200", function()
	api.guilds.bulkBan(ID, {})
end)
rejects("bulk ban rejects 201 users", "got 201", function()
	api.guilds.bulkBan(ID, many)
end)
local tooMany: { string } = {}
for index = 1, 1001 do
	tooMany[index] = ID
end
rejects("bulk-add target users caps at 1000", "1 to 1000", function()
	api.invites.bulkAddTargetUsers("abc", tooMany)
end)
rejects("bulk-delete target users rejects an empty list", "1 to 1000", function()
	api.invites.bulkDeleteTargetUsers("abc", {})
end)
local record = { type = 7, key = "k", name = "n", description = "d" }
rejects("role connection metadata caps at 5", "at most 5", function()
	api.applications.updateRoleConnectionMetadata(ID, { record, record, record, record, record, record })
end)
rejects("listSubscriptions needs a user id", "needs a user id", function()
	api.monetization.listSubscriptions(ID, "")
end)
rejects("editWithToken refuses to move a webhook", "cannot move", function()
	api.webhooks.editWithToken(ID, "wtoken", { channel_id = ID2 })
end)
rejects("bulk delete still validates", "2 to 100", function()
	api.channels.bulkDeleteMessages(ID, { ID })
end)

----------------------------------------------------------------------------
-- Pure URL helpers: no request
----------------------------------------------------------------------------

do
	local before = #calls
	h.equals("widget image default", api.guilds.widgetImageUrl(ID), `{BASE}/guilds/{ID}/widget.png`)
	h.equals("widget image style", api.guilds.widgetImageUrl(ID, "banner2"), `{BASE}/guilds/{ID}/widget.png?style=banner2`)
	h.check("widget image makes no request", #calls == before)
	h.throws("widget image rejects an unknown style", "unknown widget style", function()
		api.guilds.widgetImageUrl(ID, "banner9")
	end)
end

local cdn = Api.cdn
local CDN = "https://cdn.discordapp.com"

h.check("api.cdn is Api.cdn", api.cdn == Api.cdn)
h.equals(
	"static avatar defaults to png",
	cdn.userAvatar({ id = ID, avatar = "abc123" }),
	`{CDN}/avatars/{ID}/abc123.png`
)
h.equals(
	"animated avatar defaults to gif",
	cdn.userAvatar({ id = ID, avatar = "a_abc123" }, { size = 256 }),
	`{CDN}/avatars/{ID}/a_abc123.gif?size=256`
)
h.equals(
	"animated avatar as webp asks for animation",
	cdn.userAvatar({ id = ID, avatar = "a_abc123" }, { format = "webp" }),
	`{CDN}/avatars/{ID}/a_abc123.webp?animated=true`
)
h.equals(
	"animated = false gives a still frame",
	cdn.userAvatar({ id = ID, avatar = "a_abc123" }, { animated = false }),
	`{CDN}/avatars/{ID}/a_abc123.png`
)
h.equals(
	"legacy discriminator picks discriminator % 5",
	cdn.userAvatar({ id = ID, avatar = nil, discriminator = "1337" }),
	`{CDN}/embed/avatars/2.png`
)

-- (2^40 + 1) * 2^22 - 1: the double nearest this id is the next multiple of
-- 2^22, so `tonumber(id) // 2^22` is one too high and picks the wrong avatar.
local tricky = "4611686018431582207"
local viaFloat = (math.floor((tonumber(tricky) :: number) / 4194304)) % 6
h.check("the tricky id really does fool float math", viaFloat ~= 4)
h.equals(
	"new-username default avatar is (id >> 22) % 6, exactly",
	cdn.defaultAvatar({ id = tricky, discriminator = "0" }),
	`{CDN}/embed/avatars/4.png`
)
h.equals(
	"a missing discriminator counts as migrated",
	cdn.userAvatar({ id = tricky }),
	`{CDN}/embed/avatars/4.png`
)

h.equals("guild icon", cdn.guildIcon(ID, "a_ic", { size = 64 }), `{CDN}/icons/{ID}/a_ic.gif?size=64`)
h.equals("guild banner", cdn.guildBanner(ID, "bn"), `{CDN}/banners/{ID}/bn.png`)
h.equals("guild splash", cdn.guildSplash(ID, "sp", { format = "jpg" }), `{CDN}/splashes/{ID}/sp.jpg`)
h.equals("guild discovery splash", cdn.guildDiscoverySplash(ID, "ds"), `{CDN}/discovery-splashes/{ID}/ds.png`)
h.equals("user banner", cdn.userBanner(ID, "a_ub"), `{CDN}/banners/{ID}/a_ub.gif`)
h.equals(
	"member avatar",
	cdn.memberAvatar(ID, ID2, "ma", { size = 128 }),
	`{CDN}/guilds/{ID}/users/{ID2}/avatars/ma.png?size=128`
)
h.equals("member banner", cdn.memberBanner(ID, ID2, "mb"), `{CDN}/guilds/{ID}/users/{ID2}/banners/mb.png`)
h.equals("role icon", cdn.roleIcon(ID, "ri"), `{CDN}/role-icons/{ID}/ri.png`)
h.equals("application icon", cdn.applicationIcon(ID, "ai", { format = "webp" }), `{CDN}/app-icons/{ID}/ai.webp`)
h.equals("scheduled event cover", cdn.scheduledEventCover(ID, "ev"), `{CDN}/guild-events/{ID}/ev.png`)
h.equals(
	"sticker pack banner",
	cdn.stickerPackBanner(ID),
	`{CDN}/app-assets/710982414301790216/store/{ID}.png`
)
h.equals("static emoji defaults to webp", cdn.emoji(ID), `{CDN}/emojis/{ID}.webp`)
h.equals("animated emoji is animated webp", cdn.emoji(ID, true), `{CDN}/emojis/{ID}.webp?animated=true`)
h.equals("animated emoji as gif", cdn.emoji(ID, true, { format = "gif", size = 64 }), `{CDN}/emojis/{ID}.gif?size=64`)
h.equals("png sticker", cdn.sticker({ id = ID, format_type = 1 }), `{CDN}/stickers/{ID}.png`)
h.equals("apng sticker is png", cdn.sticker({ id = ID, format_type = 2 }), `{CDN}/stickers/{ID}.png`)
h.equals("lottie sticker is json", cdn.sticker({ id = ID, format_type = 3 }), `{CDN}/stickers/{ID}.json`)
h.equals(
	"gif sticker lives on the media host",
	cdn.sticker({ id = ID, format_type = 4 }),
	`https://media.discordapp.net/stickers/{ID}.gif`
)

h.throws("size must be a power of two", "power of two", function()
	cdn.guildIcon(ID, "ic", { size = 100 })
end)
h.throws("size must be at least 16", "power of two", function()
	cdn.emoji(ID, false, { size = 8 })
end)
h.throws("gif needs an animated hash", "animated", function()
	cdn.guildIcon(ID, "static", { format = "gif" })
end)
h.throws("gif needs an animated emoji", "animated", function()
	cdn.emoji(ID, false, { format = "gif" })
end)
h.throws("unknown format is rejected", "unknown CDN format", function()
	cdn.roleIcon(ID, "ri", { format = "bmp" })
end)
h.throws("default avatar rejects a non-numeric id", "not a snowflake", function()
	cdn.defaultAvatar({ id = "12ab" })
end)

----------------------------------------------------------------------------
-- Empty bodies, list bodies, and where uploads' attachments go
----------------------------------------------------------------------------

local function payloadJson(): any
	local text = string.match(last().body or "", 'name="payload_json"\r\nContent%-Type: application/json\r\n\r\n(.-)\r\n%-%-')
	return if text ~= nil then (Json.decode(text)) else nil
end

respond(200, `\{"pruned":0}`)
api.guilds.beginPrune(ID, {})
h.equals("beginPrune with no options sends an object", last().body, "{}")
api.guilds.editCurrentMember(ID, {})
h.equals("a patch with every field nil sends an object", last().body, "{}")
api.guilds.editWidget(ID, {})
h.equals("editWidget with nothing set sends an object", last().body, "{}")
api.applications.bulkOverwriteGuildCommands(ID, ID2, {})
h.equals("bulk overwrite with no commands still sends a list", last().body, "[]")
api.applications.bulkOverwriteGlobalCommands(ID, {})
h.equals("global bulk overwrite with no commands sends a list", last().body, "[]")
api.guilds.editChannelPositions(ID, {})
h.equals("an empty position list stays a list", last().body, "[]")

respond(204, "")
api.interactions.createResponse(ID, "itoken", 5, {})
h.check("an empty callback data is omitted, not sent as []", last().body == `\{"type":5}` or string.find(last().body or "", "[]", 1, true) == nil)
h.equals("the callback type survives", body().type, 5)

respond(204, "")
api.interactions.createResponse(ID, "itoken", 4, { content = "pic" }, { { name = "a.png", data = "A", description = "alt" } })
do
	local payload = payloadJson()
	h.equals("a callback's attachments go inside data", payload and payload.data.attachments[1].description, "alt")
	h.equals("and not at the top level", payload and payload.attachments, nil)
end

respond(200, `\{"interaction":\{"id":"{ID}","type":2},"resource":\{"type":4}}`)
api.interactions.createResponseWithResult(ID, "itoken", 4, { content = "pic" }, { png("b.png") })
h.check("with_response callbacks nest attachments too", (payloadJson() or {}).data ~= nil and payloadJson().data.attachments[1].filename == "b.png")

respond(200, `\{"id":"{ID3}"}`)
api.channels.createForumPost(ID, "post", { content = "hello", files = { { name = "c.txt", data = "C", description = "notes" } } })
do
	local payload = payloadJson()
	h.equals("a forum post's attachments go inside message", payload and payload.message.attachments[1].description, "notes")
	h.equals("and not beside it", payload and payload.attachments, nil)
end

api.channels.editMessage(ID, ID2, { content = "plus a file", files = { png("more.png") } })
h.equals("an edit that only adds a file leaves attachments out, so Discord appends", (payloadJson() or {}).attachments, nil)

----------------------------------------------------------------------------
-- Interaction routes are outside the global rate limit
----------------------------------------------------------------------------
do
	local held = Http.new("tkn", { transport = fake, baseUrl = BASE })
	local heldApi = Api.new(held)
	held.globalResetAt = Util.now()
	held.globalWait = 5
	local started = Util.now()
	respond(204, "")
	heldApi.interactions.createResponse(ID, "itoken", 5)
	heldApi.interactions.createFollowup(ID, "itoken", "follow")
	heldApi.interactions.editOriginalResponse(ID, "itoken", "edited")
	h.check("interaction routes do not wait out a global pause", Util.since(started) < 1)
	held.globalResetAt = nil
end

----------------------------------------------------------------------------
-- Bulk delete refuses messages past Discord's 14-day line
----------------------------------------------------------------------------
do
	local Snowflake = require("@discord/snowflake")
	local now = os.time()
	local fresh = Snowflake.fromTimestamp(now - 60)
	local fresh2 = Snowflake.fromTimestamp(now - 3600)
	local old = Snowflake.fromTimestamp(now - 15 * 86400)
	local edge = Snowflake.fromTimestamp(now - 14 * 86400 + 30)
	local before = #calls
	rejects("bulk delete names how many messages are too old", "2 of 4 are too old", function()
		api.channels.bulkDeleteMessages(ID, { fresh, old, fresh2, edge })
	end)
	h.equals("and sends nothing", #calls, before)
	api.channels.bulkDeleteMessages(ID, { fresh, fresh2 })
	h.equals("recent messages go through", last().path, `/channels/{ID}/messages/bulk-delete`)
end

h.finish()
