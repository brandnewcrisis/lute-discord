--!strict
--[[
	The endpoint surface: one Luau function per Discord REST route.

	This layer is deliberately thin and mechanical. It knows path shapes,
	which arguments are query parameters, and where an audit-log reason is
	accepted -- nothing else. All the judgement (rate limits, retries,
	multipart) lives in `@discord/http`, and all the ergonomics (builders,
	ephemeral, caching) live above it in `@discord/client`, so this file
	stays a readable map of the API rather than a pile of special cases.

	Every method throws an `ApiError` on failure; see `@discord/error`.
	`Api.cdn` is the one exception to "one function per route": it builds
	CDN URLs and never makes a request.
]]
local Const = require("@discord/const")
local Http = require("@discord/http")
local Json = require("@discord/json")
local Payload = require("@discord/payload")
local Snowflake = require("@discord/snowflake")
local Types = require("@discord/types")
local Util = require("@discord/util")

type Snowflake = Types.Snowflake

local Api = {}

--- A command payload, or a `@discord/commands` builder that yields one.
--- Both reach Discord the same way; `Payload.toJSON` unwraps the builder.
export type CommandInput = Types.Buildable<Types.ApplicationCommand>

--- Splits `files` out of a message-shaped payload: they travel as multipart
--- parts, not as a JSON field. Edit routes pass `{ edit = true }`; see
--- `Payload.MessageOptions`.
local function split(input: Types.MessageInput, options: Payload.MessageOptions?): (Types.MessageBody, { Http.File }?)
	local body = Payload.message(input, options)
	local files = body.files
	body.files = nil
	return body, files
end

--- The mode every PATCH of an existing message passes to `split`.
local EDIT: Payload.MessageOptions = { edit = true }

--- Errors against the caller's line when a list is outside what Discord
--- accepts. Used where Discord's own answer is a bare 400.
local function checkCount(what: string, list: { any }, min: number, max: number)
	if #list < min or #list > max then
		error(`{what} takes {min} to {max} ids, got {#list}`, 3)
	end
end

-- Discord's bulk-delete cutoff (14 days), less a minute of clock slack.
local BULK_DELETE_MAX_AGE = 14 * 24 * 60 * 60 - 60

local function makeChannels(http: Http.Http)
	local channels = {}

	function channels.get(channelId: Snowflake): Types.Channel
		return http:get(`/channels/{channelId}`)
	end

	function channels.edit(channelId: Snowflake, patch: Types.ChannelPatch, reason: string?): Types.Channel
		return http:patch(`/channels/{channelId}`, { body = patch, reason = reason })
	end

	function channels.delete(channelId: Snowflake, reason: string?): Types.Channel
		return http:delete(`/channels/{channelId}`, { reason = reason })
	end

	--- `limit` caps at 100; use `before` with the oldest id seen to page back.
	function channels.getMessages(
		channelId: Snowflake,
		query: { limit: number?, before: Snowflake?, after: Snowflake?, around: Snowflake? }?
	): { Types.Message }
		return http:get(`/channels/{channelId}/messages`, { query = query })
	end

	function channels.getMessage(channelId: Snowflake, messageId: Snowflake): Types.Message
		return http:get(`/channels/{channelId}/messages/{messageId}`)
	end

	function channels.createMessage(channelId: Snowflake, payload: Types.MessageInput): Types.Message
		local body, files = split(payload)
		return http:post(`/channels/{channelId}/messages`, { body = body, files = files })
	end

	--[[
		Every field is optional: only the ones given change. New files are
		appended; to remove or replace existing ones, pass `attachments`
		listing the ones to keep (by id).
	]]
	function channels.editMessage(channelId: Snowflake, messageId: Snowflake, payload: Types.MessageInput): Types.Message
		local body, files = split(payload, EDIT)
		return http:patch(`/channels/{channelId}/messages/{messageId}`, { body = body, files = files })
	end

	function channels.deleteMessage(channelId: Snowflake, messageId: Snowflake, reason: string?)
		http:delete(`/channels/{channelId}/messages/{messageId}`, { reason = reason })
	end

	--[[
		Bulk delete. Discord requires 2-100 ids, none older than 14 days, and
		answers a violation with a generic 400 -- so both rules are checked
		here where the message can name the actual problem.
	]]
	function channels.bulkDeleteMessages(channelId: Snowflake, messageIds: { Snowflake }, reason: string?)
		if #messageIds < 2 or #messageIds > 100 then
			error(`bulk delete takes 2 to 100 messages, got {#messageIds}`, 2)
		end
		-- A minute short of 14 days: our clock and Discord's differ, and a
		-- message right at the line would pass here and still be refused.
		local tooOld = 0
		for _, id in messageIds do
			if Snowflake.age(id) > BULK_DELETE_MAX_AGE then
				tooOld += 1
			end
		end
		if tooOld > 0 then
			error(
				`bulk delete cannot remove messages older than 14 days; {tooOld} of {#messageIds} are too old `
					.. "(delete those one at a time with deleteMessage)",
				2
			)
		end
		http:post(`/channels/{channelId}/messages/bulk-delete`, {
			body = { messages = messageIds },
			reason = reason,
		})
	end

	function channels.crosspostMessage(channelId: Snowflake, messageId: Snowflake): Types.Message
		return http:post(`/channels/{channelId}/messages/{messageId}/crosspost`)
	end

	--- `emoji` is a unicode character, or `name:id` for a custom one.
	function channels.addReaction(channelId: Snowflake, messageId: Snowflake, emoji: string)
		http:put(`/channels/{channelId}/messages/{messageId}/reactions/{Util.encodeComponent(emoji)}/@me`)
	end

	function channels.deleteOwnReaction(channelId: Snowflake, messageId: Snowflake, emoji: string)
		http:delete(`/channels/{channelId}/messages/{messageId}/reactions/{Util.encodeComponent(emoji)}/@me`)
	end

	function channels.deleteUserReaction(
		channelId: Snowflake,
		messageId: Snowflake,
		emoji: string,
		userId: Snowflake
	)
		http:delete(`/channels/{channelId}/messages/{messageId}/reactions/{Util.encodeComponent(emoji)}/{userId}`)
	end

	--- `type` is `Const.ReactionType`. Super reactions (BURST) are listed
	--- separately, so a plain call misses everyone who only super-reacted.
	function channels.getReactions(
		channelId: Snowflake,
		messageId: Snowflake,
		emoji: string,
		query: { limit: number?, after: Snowflake?, type: number? }?
	): { Types.User }
		return http:get(
			`/channels/{channelId}/messages/{messageId}/reactions/{Util.encodeComponent(emoji)}`,
			{ query = query }
		)
	end

	function channels.deleteAllReactions(channelId: Snowflake, messageId: Snowflake)
		http:delete(`/channels/{channelId}/messages/{messageId}/reactions`)
	end

	function channels.deleteEmojiReactions(channelId: Snowflake, messageId: Snowflake, emoji: string)
		http:delete(`/channels/{channelId}/messages/{messageId}/reactions/{Util.encodeComponent(emoji)}`)
	end

	--- A bot can only allow or deny bits it holds itself, unless it has
	--- MANAGE_ROLES as an overwrite in this channel.
	function channels.editPermissions(
		channelId: Snowflake,
		overwriteId: Snowflake,
		overwrite: Types.OverwritePatch,
		reason: string?
	)
		http:put(`/channels/{channelId}/permissions/{overwriteId}`, { body = overwrite, reason = reason })
	end

	function channels.deletePermission(channelId: Snowflake, overwriteId: Snowflake, reason: string?)
		http:delete(`/channels/{channelId}/permissions/{overwriteId}`, { reason = reason })
	end

	function channels.getInvites(channelId: Snowflake): { Types.Invite }
		return http:get(`/channels/{channelId}/invites`)
	end

	--- The body is mandatory even with no options, and must be `{}`: an
	--- empty Luau table would serialise as `[]`, which Discord rejects.
	function channels.createInvite(channelId: Snowflake, options: Types.InviteCreate?, reason: string?): Types.Invite
		local body = if options == nil or next(options) == nil then Json.object() else options
		return http:post(`/channels/{channelId}/invites`, { body = body, reason = reason })
	end

	--- Shows the typing indicator for ~10s. Worth firing before slow work so
	--- the channel does not look dead.
	function channels.triggerTyping(channelId: Snowflake)
		http:post(`/channels/{channelId}/typing`)
	end

	--- Deprecated by Discord in favour of `getPins`, and capped at the first
	--- 50 pins with no way to page further. Kept because it still works.
	function channels.getPinnedMessages(channelId: Snowflake): { Types.Message }
		return http:get(`/channels/{channelId}/pins`)
	end

	--[[
		The paginated pin list. Unlike the old route this pages by TIME, not
		id: pass the last item's `pinned_at` as `before`. `limit` is 1-50.
	]]
	function channels.getPins(channelId: Snowflake, query: { before: string?, limit: number? }?): Types.PinList
		return http:get(`/channels/{channelId}/messages/pins`, { query = query })
	end

	--- Needs PIN_MESSAGES; MANAGE_MESSAGES stopped being enough in 2026.
	function channels.pinMessage(channelId: Snowflake, messageId: Snowflake, reason: string?)
		http:put(`/channels/{channelId}/messages/pins/{messageId}`, { reason = reason })
	end

	function channels.unpinMessage(channelId: Snowflake, messageId: Snowflake, reason: string?)
		http:delete(`/channels/{channelId}/messages/pins/{messageId}`, { reason = reason })
	end

	--- Up to 500 characters; `nil` clears it. Needs SET_VOICE_CHANNEL_STATUS,
	--- and MANAGE_CHANNELS too unless the bot is connected to the channel.
	function channels.setVoiceStatus(channelId: Snowflake, status: string?, reason: string?)
		http:put(`/channels/{channelId}/voice-status`, {
			body = { status = if status == nil then Json.null else status },
			reason = reason,
		})
	end

	function channels.startThread(channelId: Snowflake, options: Types.ThreadCreate, reason: string?): Types.Channel
		return http:post(`/channels/{channelId}/threads`, { body = options, reason = reason })
	end

	function channels.startThreadFromMessage(
		channelId: Snowflake,
		messageId: Snowflake,
		options: Types.ThreadCreate,
		reason: string?
	): Types.Channel
		return http:post(`/channels/{channelId}/messages/{messageId}/threads`, { body = options, reason = reason })
	end

	--[[
		Opens a post in a forum or media channel.

		The same route as `startThread`, but a forum thread is invalid without
		a starter `message`, and the failure is a flat 400 that does not say
		so. Taking the message as its own argument means the shape cannot be
		got wrong, and it goes through `split` so a post can carry files.

		`appliedTags` are forum tag ids -- read them off the channel object,
		they are not names.
	]]
	function channels.createForumPost(
		channelId: Snowflake,
		name: string,
		message: Types.MessageInput,
		options: { appliedTags: { Snowflake }?, autoArchiveDuration: number?, rateLimitPerUser: number? }?,
		reason: string?
	): Types.Channel
		local extra: { appliedTags: { Snowflake }?, autoArchiveDuration: number?, rateLimitPerUser: number? } =
			options or {}
		local body, files = split(message)
		return http:post(`/channels/{channelId}/threads`, {
			body = {
				name = name,
				message = body,
				applied_tags = extra.appliedTags,
				auto_archive_duration = extra.autoArchiveDuration,
				rate_limit_per_user = extra.rateLimitPerUser,
			},
			files = files,
			-- The uploads belong to the starter message, not the thread.
			attachmentsPath = "message",
			reason = reason,
		})
	end

	function channels.joinThread(channelId: Snowflake)
		http:put(`/channels/{channelId}/thread-members/@me`)
	end

	function channels.leaveThread(channelId: Snowflake)
		http:delete(`/channels/{channelId}/thread-members/@me`)
	end

	function channels.addThreadMember(channelId: Snowflake, userId: Snowflake)
		http:put(`/channels/{channelId}/thread-members/{userId}`)
	end

	function channels.removeThreadMember(channelId: Snowflake, userId: Snowflake)
		http:delete(`/channels/{channelId}/thread-members/{userId}`)
	end

	--- 404s (an `ApiError`) when the user is not in the thread.
	function channels.getThreadMember(channelId: Snowflake, userId: Snowflake, withMember: boolean?): Types.ThreadMember
		return http:get(`/channels/{channelId}/thread-members/{userId}`, { query = { with_member = withMember } })
	end

	--[[
		Needs the GUILD_MEMBERS privileged intent. `with_member = true` is
		also what switches on pagination (`after` / `limit`); without it
		Discord ignores both and returns everyone. API v11 will always page.
	]]
	function channels.listThreadMembers(channelId: Snowflake, query: Types.ThreadMembersQuery?): { Types.ThreadMember }
		return http:get(`/channels/{channelId}/thread-members`, { query = query })
	end

	--- Needs READ_MESSAGE_HISTORY. `before` is an ISO timestamp, not an id.
	function channels.listPublicArchivedThreads(channelId: Snowflake, query: Types.ArchivedThreadsQuery?): Types.ThreadList
		return http:get(`/channels/{channelId}/threads/archived/public`, { query = query })
	end

	--- Needs READ_MESSAGE_HISTORY and MANAGE_THREADS. `before` is an ISO timestamp.
	function channels.listPrivateArchivedThreads(channelId: Snowflake, query: Types.ArchivedThreadsQuery?): Types.ThreadList
		return http:get(`/channels/{channelId}/threads/archived/private`, { query = query })
	end

	--- Only threads the bot has joined, so no MANAGE_THREADS. Unlike the two
	--- routes above, `before` here is a thread ID.
	function channels.listJoinedPrivateArchivedThreads(
		channelId: Snowflake,
		query: Types.ArchivedThreadsQuery?
	): Types.ThreadList
		return http:get(`/channels/{channelId}/users/@me/threads/archived/private`, { query = query })
	end

	function channels.followAnnouncementChannel(
		channelId: Snowflake,
		targetChannelId: Snowflake,
		reason: string?
	): Types.FollowedChannel
		return http:post(`/channels/{channelId}/followers`, {
			body = { webhook_channel_id = targetChannelId },
			reason = reason,
		})
	end

	return channels
end

local function makeGuilds(http: Http.Http)
	local guilds = {}

	function guilds.get(guildId: Snowflake, withCounts: boolean?): Types.Guild
		return http:get(`/guilds/{guildId}`, { query = { with_counts = withCounts } })
	end

	--- Works on guilds the bot is not in only if they are discoverable.
	function guilds.getPreview(guildId: Snowflake): Types.GuildPreview
		return http:get(`/guilds/{guildId}/preview`)
	end

	function guilds.edit(guildId: Snowflake, patch: Types.GuildPatch, reason: string?): Types.Guild
		return http:patch(`/guilds/{guildId}`, { body = patch, reason = reason })
	end

	function guilds.getChannels(guildId: Snowflake): { Types.Channel }
		return http:get(`/guilds/{guildId}/channels`)
	end

	function guilds.createChannel(guildId: Snowflake, options: Types.ChannelCreate, reason: string?): Types.Channel
		return http:post(`/guilds/{guildId}/channels`, { body = options, reason = reason })
	end

	function guilds.editChannelPositions(guildId: Snowflake, positions: { Types.ChannelPosition })
		http:patch(`/guilds/{guildId}/channels`, { body = positions, list = true })
	end

	function guilds.listActiveThreads(guildId: Snowflake): Types.ThreadList
		return http:get(`/guilds/{guildId}/threads/active`)
	end

	function guilds.getMember(guildId: Snowflake, userId: Snowflake): Types.Member
		return http:get(`/guilds/{guildId}/members/{userId}`)
	end

	--- Requires the GUILD_MEMBERS privileged intent to return more than the
	--- members Discord already considers visible.
	function guilds.listMembers(
		guildId: Snowflake,
		query: { limit: number?, after: Snowflake? }?
	): { Types.Member }
		return http:get(`/guilds/{guildId}/members`, { query = query })
	end

	--- Prefix search by username or nickname. Needs no privileged intent,
	--- which makes it the practical way to look members up.
	function guilds.searchMembers(guildId: Snowflake, name: string, limit: number?): { Types.Member }
		return http:get(`/guilds/{guildId}/members/search`, { query = { query = name, limit = limit or 10 } })
	end

	--[[
		Pulls a user into the guild with their OAuth2 token (`guilds.join`
		scope, granted to THIS application). The request itself still goes
		out with the bot token, and the bot needs CREATE_INSTANT_INVITE.
		Returns nil when the user was already a member.
	]]
	function guilds.addMember(guildId: Snowflake, userId: Snowflake, options: Types.MemberAdd): Types.Member?
		return http:put(`/guilds/{guildId}/members/{userId}`, { body = options })
	end

	function guilds.editMember(guildId: Snowflake, userId: Snowflake, patch: Types.MemberPatch, reason: string?): Types.Member
		return http:patch(`/guilds/{guildId}/members/{userId}`, { body = patch, reason = reason })
	end

	function guilds.editCurrentMember(guildId: Snowflake, patch: Types.MemberPatch, reason: string?): Types.Member
		return http:patch(`/guilds/{guildId}/members/@me`, { body = patch, reason = reason })
	end

	function guilds.addMemberRole(guildId: Snowflake, userId: Snowflake, roleId: Snowflake, reason: string?)
		http:put(`/guilds/{guildId}/members/{userId}/roles/{roleId}`, { reason = reason })
	end

	function guilds.removeMemberRole(guildId: Snowflake, userId: Snowflake, roleId: Snowflake, reason: string?)
		http:delete(`/guilds/{guildId}/members/{userId}/roles/{roleId}`, { reason = reason })
	end

	function guilds.kickMember(guildId: Snowflake, userId: Snowflake, reason: string?)
		http:delete(`/guilds/{guildId}/members/{userId}`, { reason = reason })
	end

	--- `deleteMessageSeconds` clears recent messages, 0 to 604800 (7 days).
	function guilds.banMember(
		guildId: Snowflake,
		userId: Snowflake,
		options: { deleteMessageSeconds: number? }?,
		reason: string?
	)
		-- No options means no body at all; an empty table would go out as `[]`.
		local seconds = if options then options.deleteMessageSeconds else nil
		local body = if seconds ~= nil then { delete_message_seconds = seconds } else nil
		http:put(`/guilds/{guildId}/bans/{userId}`, { body = body, reason = reason })
	end

	--[[
		Bans up to 200 users in one request. Needs BAN_MEMBERS and MANAGE_GUILD.

		Partial failure comes back in `failed_users`. Total failure does NOT:
		it is an error (code 500000), so a caller that only checks
		`failed_users` never sees the case where nobody was banned.
	]]
	function guilds.bulkBan(
		guildId: Snowflake,
		userIds: { Snowflake },
		options: { deleteMessageSeconds: number? }?,
		reason: string?
	): Types.BulkBanResult
		checkCount("bulk ban", userIds, 1, 200)
		return http:post(`/guilds/{guildId}/bulk-ban`, {
			body = {
				user_ids = userIds,
				delete_message_seconds = if options then options.deleteMessageSeconds else nil,
			},
			reason = reason,
		})
	end

	function guilds.unbanMember(guildId: Snowflake, userId: Snowflake, reason: string?)
		http:delete(`/guilds/{guildId}/bans/{userId}`, { reason = reason })
	end

	function guilds.getBans(guildId: Snowflake, query: { limit: number?, before: Snowflake?, after: Snowflake? }?): { Types.Ban }
		return http:get(`/guilds/{guildId}/bans`, { query = query })
	end

	function guilds.getBan(guildId: Snowflake, userId: Snowflake): Types.Ban
		return http:get(`/guilds/{guildId}/bans/{userId}`)
	end

	function guilds.getRoles(guildId: Snowflake): { Types.Role }
		return http:get(`/guilds/{guildId}/roles`)
	end

	function guilds.getRole(guildId: Snowflake, roleId: Snowflake): Types.Role
		return http:get(`/guilds/{guildId}/roles/{roleId}`)
	end

	--- Role id -> member count. @everyone is left out.
	function guilds.getRoleMemberCounts(guildId: Snowflake): { [Snowflake]: number }
		return http:get(`/guilds/{guildId}/roles/member-counts`)
	end

	function guilds.createRole(guildId: Snowflake, options: Types.RolePatch, reason: string?): Types.Role
		return http:post(`/guilds/{guildId}/roles`, { body = options, reason = reason })
	end

	function guilds.editRole(guildId: Snowflake, roleId: Snowflake, patch: Types.RolePatch, reason: string?): Types.Role
		return http:patch(`/guilds/{guildId}/roles/{roleId}`, { body = patch, reason = reason })
	end

	function guilds.editRolePositions(guildId: Snowflake, positions: { Types.RolePosition }, reason: string?): { Types.Role }
		return http:patch(`/guilds/{guildId}/roles`, { body = positions, reason = reason, list = true })
	end

	function guilds.deleteRole(guildId: Snowflake, roleId: Snowflake, reason: string?)
		http:delete(`/guilds/{guildId}/roles/{roleId}`, { reason = reason })
	end

	function guilds.getPruneCount(guildId: Snowflake, days: number?): Types.PruneResult
		return http:get(`/guilds/{guildId}/prune`, { query = { days = days } })
	end

	function guilds.beginPrune(guildId: Snowflake, options: Types.PruneOptions, reason: string?): Types.PruneResult
		return http:post(`/guilds/{guildId}/prune`, { body = options, reason = reason })
	end

	--- Unlike `voice.listRegions`, this includes VIP regions for VIP guilds.
	function guilds.getVoiceRegions(guildId: Snowflake): { Types.VoiceRegion }
		return http:get(`/guilds/{guildId}/regions`)
	end

	function guilds.getInvites(guildId: Snowflake): { Types.Invite }
		return http:get(`/guilds/{guildId}/invites`)
	end

	--- Hard-capped at 50; a guild with more cannot list the rest at all.
	function guilds.getIntegrations(guildId: Snowflake): { Types.Integration }
		return http:get(`/guilds/{guildId}/integrations`)
	end

	--- Also deletes the integration's webhooks and kicks its bot, if any.
	function guilds.deleteIntegration(guildId: Snowflake, integrationId: Snowflake, reason: string?)
		http:delete(`/guilds/{guildId}/integrations/{integrationId}`, { reason = reason })
	end

	function guilds.getEmojis(guildId: Snowflake): { Types.Emoji }
		return http:get(`/guilds/{guildId}/emojis`)
	end

	function guilds.getEmoji(guildId: Snowflake, emojiId: Snowflake): Types.Emoji
		return http:get(`/guilds/{guildId}/emojis/{emojiId}`)
	end

	--- `image` must be a `data:` URI -- see `Util.dataUri`.
	function guilds.createEmoji(guildId: Snowflake, options: { name: string, image: string, roles: { Snowflake }? }, reason: string?): Types.Emoji
		return http:post(`/guilds/{guildId}/emojis`, { body = options, reason = reason })
	end

	function guilds.editEmoji(guildId: Snowflake, emojiId: Snowflake, patch: Types.EmojiPatch, reason: string?): Types.Emoji
		return http:patch(`/guilds/{guildId}/emojis/{emojiId}`, { body = patch, reason = reason })
	end

	function guilds.deleteEmoji(guildId: Snowflake, emojiId: Snowflake, reason: string?)
		http:delete(`/guilds/{guildId}/emojis/{emojiId}`, { reason = reason })
	end

	function guilds.getAuditLog(guildId: Snowflake, query: Types.AuditLogQuery?): Types.AuditLog
		return http:get(`/guilds/{guildId}/audit-logs`, { query = query })
	end

	function guilds.getScheduledEvents(guildId: Snowflake, withUserCount: boolean?): { Types.ScheduledEvent }
		return http:get(`/guilds/{guildId}/scheduled-events`, { query = { with_user_count = withUserCount } })
	end

	function guilds.getScheduledEvent(guildId: Snowflake, eventId: Snowflake, withUserCount: boolean?): Types.ScheduledEvent
		return http:get(`/guilds/{guildId}/scheduled-events/{eventId}`, { query = { with_user_count = withUserCount } })
	end

	function guilds.createScheduledEvent(guildId: Snowflake, options: Types.ScheduledEventCreate, reason: string?): Types.ScheduledEvent
		return http:post(`/guilds/{guildId}/scheduled-events`, { body = options, reason = reason })
	end

	function guilds.editScheduledEvent(guildId: Snowflake, eventId: Snowflake, patch: Types.ScheduledEventPatch, reason: string?): Types.ScheduledEvent
		return http:patch(`/guilds/{guildId}/scheduled-events/{eventId}`, { body = patch, reason = reason })
	end

	function guilds.deleteScheduledEvent(guildId: Snowflake, eventId: Snowflake)
		http:delete(`/guilds/{guildId}/scheduled-events/{eventId}`)
	end

	--- Always ascending by user id. If both `before` and `after` are given
	--- only `before` counts, so a range between the two cannot be fetched.
	function guilds.getScheduledEventUsers(
		guildId: Snowflake,
		eventId: Snowflake,
		query: Types.ScheduledEventUsersQuery?
	): { Types.ScheduledEventUser }
		return http:get(`/guilds/{guildId}/scheduled-events/{eventId}/users`, { query = query })
	end

	function guilds.getVanityUrl(guildId: Snowflake): Types.VanityUrl
		return http:get(`/guilds/{guildId}/vanity-url`)
	end

	--- The public widget JSON. The widget must be enabled first, see `editWidget`.
	function guilds.getWidget(guildId: Snowflake): Types.GuildWidget
		return http:get(`/guilds/{guildId}/widget.json`)
	end

	function guilds.getWidgetSettings(guildId: Snowflake): Types.GuildWidgetSettings
		return http:get(`/guilds/{guildId}/widget`)
	end

	function guilds.editWidget(guildId: Snowflake, patch: Types.GuildWidgetPatch, reason: string?): Types.GuildWidgetSettings
		return http:patch(`/guilds/{guildId}/widget`, { body = patch, reason = reason })
	end

	local WIDGET_STYLES = { shield = true, banner1 = true, banner2 = true, banner3 = true, banner4 = true }

	--[[
		The URL of the guild's widget PNG. Returns a string and makes no
		request: the image is public and meant to be embedded, so the useful
		thing is the link. `style` is "shield" (default) or "banner1".."banner4".
	]]
	function guilds.widgetImageUrl(guildId: Snowflake, style: string?): string
		if style ~= nil and not WIDGET_STYLES[style] then
			error(`unknown widget style "{style}": use shield or banner1-4`, 2)
		end
		return `{http.baseUrl}/guilds/{guildId}/widget.png{Util.query({ style = style })}`
	end

	--- Needs MANAGE_GUILD when the welcome screen is disabled.
	function guilds.getWelcomeScreen(guildId: Snowflake): Types.WelcomeScreen
		return http:get(`/guilds/{guildId}/welcome-screen`)
	end

	function guilds.editWelcomeScreen(guildId: Snowflake, patch: Types.WelcomeScreenPatch, reason: string?): Types.WelcomeScreen
		return http:patch(`/guilds/{guildId}/welcome-screen`, { body = patch, reason = reason })
	end

	function guilds.getOnboarding(guildId: Snowflake): Types.GuildOnboarding
		return http:get(`/guilds/{guildId}/onboarding`)
	end

	--[[
		Replaces the onboarding config. Needs MANAGE_GUILD and MANAGE_ROLES.
		Enabling it requires at least 7 default channels, 5 of them open to
		@everyone for sending; `mode` changes what counts toward that.
	]]
	function guilds.editOnboarding(guildId: Snowflake, patch: Types.OnboardingPatch, reason: string?): Types.GuildOnboarding
		return http:put(`/guilds/{guildId}/onboarding`, { body = patch, reason = reason })
	end

	--- Pauses invites and/or DMs for raid response, up to 24 hours ahead.
	function guilds.editIncidentActions(guildId: Snowflake, patch: Types.IncidentActionsPatch): Types.IncidentsData
		return http:put(`/guilds/{guildId}/incident-actions`, { body = patch })
	end

	--[[
		Full-text message search across the guild.

		Needs the MESSAGE_CONTENT privileged intent and READ_MESSAGE_HISTORY.
		A guild that is not indexed yet answers 202 with no results and
		`code = 110000`; retry after `retry_after` seconds. The response is
		a success, not an `ApiError`, so check `code` before reading
		`messages`. Don't page by `#messages`: Discord can return fewer
		than `limit` even when more results exist.
	]]
	function guilds.searchMessages(guildId: Snowflake, query: Types.GuildMessageSearchQuery): Types.GuildMessageSearch
		return http:get(`/guilds/{guildId}/messages/search`, { query = query })
	end

	--- Template codes are strings, not ids.
	function guilds.getTemplate(code: string): Types.GuildTemplate
		return http:get(`/guilds/templates/{Util.encodeComponent(code)}`)
	end

	function guilds.getTemplates(guildId: Snowflake): { Types.GuildTemplate }
		return http:get(`/guilds/{guildId}/templates`)
	end

	function guilds.createTemplate(guildId: Snowflake, options: Types.GuildTemplateCreate): Types.GuildTemplate
		return http:post(`/guilds/{guildId}/templates`, { body = options })
	end

	--- Re-snapshots the guild into the template.
	function guilds.syncTemplate(guildId: Snowflake, code: string): Types.GuildTemplate
		return http:put(`/guilds/{guildId}/templates/{Util.encodeComponent(code)}`)
	end

	function guilds.editTemplate(guildId: Snowflake, code: string, patch: Types.GuildTemplatePatch): Types.GuildTemplate
		return http:patch(`/guilds/{guildId}/templates/{Util.encodeComponent(code)}`, { body = patch })
	end

	function guilds.deleteTemplate(guildId: Snowflake, code: string): Types.GuildTemplate
		return http:delete(`/guilds/{guildId}/templates/{Util.encodeComponent(code)}`)
	end

	--[[
		Auto-moderation rules.

		Worth preferring over a `messageCreate` handler that greps: these run
		on Discord's side, they fire before the message is visible, and they
		work without the `messageContent` privileged intent -- which a bot
		filtering chat itself cannot do at all since 2022.
	]]
	function guilds.getAutoModRules(guildId: Snowflake): { Types.AutoModRule }
		return http:get(`/guilds/{guildId}/auto-moderation/rules`)
	end

	function guilds.getAutoModRule(guildId: Snowflake, ruleId: Snowflake): Types.AutoModRule
		return http:get(`/guilds/{guildId}/auto-moderation/rules/{ruleId}`)
	end

	function guilds.createAutoModRule(guildId: Snowflake, options: Types.AutoModRuleCreate, reason: string?): Types.AutoModRule
		return http:post(`/guilds/{guildId}/auto-moderation/rules`, { body = options, reason = reason })
	end

	function guilds.editAutoModRule(guildId: Snowflake, ruleId: Snowflake, patch: Types.AutoModRulePatch, reason: string?): Types.AutoModRule
		return http:patch(`/guilds/{guildId}/auto-moderation/rules/{ruleId}`, { body = patch, reason = reason })
	end

	function guilds.deleteAutoModRule(guildId: Snowflake, ruleId: Snowflake, reason: string?)
		http:delete(`/guilds/{guildId}/auto-moderation/rules/{ruleId}`, { reason = reason })
	end

	return guilds
end

local function makeStickers(http: Http.Http)
	local stickers = {}

	function stickers.get(stickerId: Snowflake): Types.Sticker
		return http:get(`/stickers/{stickerId}`)
	end

	function stickers.listPacks(): { sticker_packs: { Types.StickerPack } }
		return http:get("/sticker-packs")
	end

	function stickers.getPack(packId: Snowflake): Types.StickerPack
		return http:get(`/sticker-packs/{packId}`)
	end

	function stickers.list(guildId: Snowflake): { Types.Sticker }
		return http:get(`/guilds/{guildId}/stickers`)
	end

	function stickers.getGuildSticker(guildId: Snowflake, stickerId: Snowflake): Types.Sticker
		return http:get(`/guilds/{guildId}/stickers/{stickerId}`)
	end

	--[[
		Uploads a guild sticker. Needs CREATE_GUILD_EXPRESSIONS.

		Unlike every other upload, this route takes a plain form (`name`,
		`description`, `tags`, `file`) and rejects `payload_json`, so it
		cannot go through `split`. Lottie stickers need a VERIFIED or
		PARTNERED guild.
	]]
	function stickers.create(guildId: Snowflake, options: Types.StickerCreate, reason: string?): Types.Sticker
		return http:post(`/guilds/{guildId}/stickers`, {
			form = {
				fields = {
					name = options.name,
					-- The field is required even when empty.
					description = options.description or "",
					tags = options.tags,
				},
				files = { file = options.file },
			},
			reason = reason,
		})
	end

	function stickers.edit(guildId: Snowflake, stickerId: Snowflake, patch: Types.StickerPatch, reason: string?): Types.Sticker
		return http:patch(`/guilds/{guildId}/stickers/{stickerId}`, { body = patch, reason = reason })
	end

	function stickers.delete(guildId: Snowflake, stickerId: Snowflake, reason: string?)
		http:delete(`/guilds/{guildId}/stickers/{stickerId}`, { reason = reason })
	end

	return stickers
end

local function makeSoundboard(http: Http.Http)
	local soundboard = {}

	--[[
		Plays a sound in the voice channel the bot is connected to. The bot
		must be in the channel, not deafened, muted or suppressed, and have
		SPEAK and USE_SOUNDBOARD (plus USE_EXTERNAL_SOUNDS for another
		guild's sound, in which case `sourceGuildId` is required).
	]]
	function soundboard.send(channelId: Snowflake, soundId: Snowflake, sourceGuildId: Snowflake?)
		http:post(`/channels/{channelId}/send-soundboard-sound`, {
			body = { sound_id = soundId, source_guild_id = sourceGuildId },
		})
	end

	function soundboard.listDefault(): { Types.SoundboardSound }
		return http:get("/soundboard-default-sounds")
	end

	function soundboard.list(guildId: Snowflake): { items: { Types.SoundboardSound } }
		return http:get(`/guilds/{guildId}/soundboard-sounds`)
	end

	function soundboard.get(guildId: Snowflake, soundId: Snowflake): Types.SoundboardSound
		return http:get(`/guilds/{guildId}/soundboard-sounds/{soundId}`)
	end

	--- `sound` is a `data:` URI (see `Util.dataUri`), not a file upload.
	function soundboard.create(guildId: Snowflake, options: Types.SoundboardSoundCreate, reason: string?): Types.SoundboardSound
		return http:post(`/guilds/{guildId}/soundboard-sounds`, { body = options, reason = reason })
	end

	function soundboard.edit(
		guildId: Snowflake,
		soundId: Snowflake,
		patch: Types.SoundboardSoundPatch,
		reason: string?
	): Types.SoundboardSound
		return http:patch(`/guilds/{guildId}/soundboard-sounds/{soundId}`, { body = patch, reason = reason })
	end

	function soundboard.delete(guildId: Snowflake, soundId: Snowflake, reason: string?)
		http:delete(`/guilds/{guildId}/soundboard-sounds/{soundId}`, { reason = reason })
	end

	return soundboard
end

--- Stage instances are keyed by their stage CHANNEL id; there is no route
--- that takes the instance's own id.
local function makeStageInstances(http: Http.Http)
	local stageInstances = {}

	function stageInstances.create(options: Types.StageInstanceCreate, reason: string?): Types.StageInstance
		return http:post("/stage-instances", { body = options, reason = reason })
	end

	function stageInstances.get(channelId: Snowflake): Types.StageInstance
		return http:get(`/stage-instances/{channelId}`)
	end

	function stageInstances.edit(channelId: Snowflake, patch: Types.StageInstancePatch, reason: string?): Types.StageInstance
		return http:patch(`/stage-instances/{channelId}`, { body = patch, reason = reason })
	end

	function stageInstances.delete(channelId: Snowflake, reason: string?)
		http:delete(`/stage-instances/{channelId}`, { reason = reason })
	end

	return stageInstances
end

local function makeVoice(http: Http.Http)
	local voice = {}

	function voice.listRegions(): { Types.VoiceRegion }
		return http:get("/voice/regions")
	end

	function voice.getCurrentState(guildId: Snowflake): Types.VoiceState
		return http:get(`/guilds/{guildId}/voice-states/@me`)
	end

	function voice.getUserState(guildId: Snowflake, userId: Snowflake): Types.VoiceState
		return http:get(`/guilds/{guildId}/voice-states/{userId}`)
	end

	--[[
		Stage channels only: `channel_id` must be a stage the bot has
		already joined over the gateway; this does not move it anywhere.
		Unsuppressing itself needs MUTE_MEMBERS.
	]]
	function voice.editCurrentState(guildId: Snowflake, patch: Types.CurrentVoiceStatePatch)
		http:patch(`/guilds/{guildId}/voice-states/@me`, { body = patch })
	end

	--- Stage channels only, and the user must already be in `channel_id`.
	--- Needs MUTE_MEMBERS.
	function voice.editUserState(guildId: Snowflake, userId: Snowflake, patch: Types.VoiceStatePatch)
		http:patch(`/guilds/{guildId}/voice-states/{userId}`, { body = patch })
	end

	return voice
end

local function makeUsers(http: Http.Http)
	local users = {}

	function users.getCurrent(): Types.User
		return http:get("/users/@me")
	end

	function users.get(userId: Snowflake): Types.User
		return http:get(`/users/{userId}`)
	end

	function users.editCurrent(patch: { username: string?, avatar: string?, banner: string? }): Types.User
		return http:patch("/users/@me", { body = patch })
	end

	--- Apps on large bot sharding MUST pass `shard` (0 to max_concurrency - 1
	--- from `gateway.getBot`) and call once per shard to see every guild.
	function users.getGuilds(query: {
		limit: number?,
		before: Snowflake?,
		after: Snowflake?,
		with_counts: boolean?,
		shard: number?,
	}?): { Types.Guild }
		return http:get("/users/@me/guilds", { query = query })
	end

	function users.leaveGuild(guildId: Snowflake)
		http:delete(`/users/@me/guilds/{guildId}`)
	end

	--- Opens (or returns the existing) DM channel with a user.
	function users.createDm(userId: Snowflake): Types.Channel
		return http:post("/users/@me/channels", { body = { recipient_id = userId } })
	end

	return users
end

local function makeApplications(http: Http.Http)
	local applications = {}

	function applications.getCurrent(): Types.Application
		return http:get("/applications/@me")
	end

	function applications.editCurrent(patch: Types.ApplicationPatch): Types.Application
		return http:patch("/applications/@me", { body = patch })
	end

	function applications.getGlobalCommands(appId: Snowflake, withLocalizations: boolean?): { Types.ApplicationCommand }
		return http:get(`/applications/{appId}/commands`, {
			query = { with_localizations = withLocalizations },
		})
	end

	function applications.getGlobalCommand(appId: Snowflake, commandId: Snowflake): Types.ApplicationCommand
		return http:get(`/applications/{appId}/commands/{commandId}`)
	end

	function applications.createGlobalCommand(appId: Snowflake, command: CommandInput): Types.ApplicationCommand
		return http:post(`/applications/{appId}/commands`, { body = Payload.toJSON(command) })
	end

	--- A field you send replaces the stored one outright; `options` is not
	--- merged, so send the whole list.
	function applications.editGlobalCommand(
		appId: Snowflake,
		commandId: Snowflake,
		patch: Types.Buildable<Types.ApplicationCommandPatch>
	): Types.ApplicationCommand
		return http:patch(`/applications/{appId}/commands/{commandId}`, { body = Payload.toJSON(patch) })
	end

	--[[
		Replaces the whole command set in one call.

		Always prefer this over creating commands one at a time: it is a
		single request regardless of how many commands there are, it deletes
		the ones you removed, and -- unlike per-command creates -- it does not
		burn through the 200-per-day global command creation limit.
	]]
	function applications.bulkOverwriteGlobalCommands(appId: Snowflake, commands: { CommandInput }): { Types.ApplicationCommand }
		-- An empty list deletes every command, so it must stay `[]`.
		return http:put(`/applications/{appId}/commands`, { body = Payload.toJSON(commands), list = true })
	end

	function applications.deleteGlobalCommand(appId: Snowflake, commandId: Snowflake)
		http:delete(`/applications/{appId}/commands/{commandId}`)
	end

	function applications.getGuildCommands(
		appId: Snowflake,
		guildId: Snowflake,
		withLocalizations: boolean?
	): { Types.ApplicationCommand }
		return http:get(`/applications/{appId}/guilds/{guildId}/commands`, {
			query = { with_localizations = withLocalizations },
		})
	end

	function applications.getGuildCommand(appId: Snowflake, guildId: Snowflake, commandId: Snowflake): Types.ApplicationCommand
		return http:get(`/applications/{appId}/guilds/{guildId}/commands/{commandId}`)
	end

	function applications.createGuildCommand(appId: Snowflake, guildId: Snowflake, command: CommandInput): Types.ApplicationCommand
		return http:post(`/applications/{appId}/guilds/{guildId}/commands`, { body = Payload.toJSON(command) })
	end

	function applications.editGuildCommand(
		appId: Snowflake,
		guildId: Snowflake,
		commandId: Snowflake,
		patch: Types.Buildable<Types.ApplicationCommandPatch>
	): Types.ApplicationCommand
		return http:patch(`/applications/{appId}/guilds/{guildId}/commands/{commandId}`, { body = Payload.toJSON(patch) })
	end

	--- Guild commands appear instantly; global ones can take up to an hour to
	--- propagate. Register to a test guild while developing.
	function applications.bulkOverwriteGuildCommands(
		appId: Snowflake,
		guildId: Snowflake,
		commands: { CommandInput }
	): { Types.ApplicationCommand }
		return http:put(`/applications/{appId}/guilds/{guildId}/commands`, { body = Payload.toJSON(commands), list = true })
	end

	function applications.deleteGuildCommand(appId: Snowflake, guildId: Snowflake, commandId: Snowflake)
		http:delete(`/applications/{appId}/guilds/{guildId}/commands/{commandId}`)
	end

	--[[
		Per-guild command permission overwrites.

		Only the READ side is here. Editing them needs a user's OAuth2
		Bearer token with guild and role management rights; Discord rejects
		the bot token outright, so a bot-token method would only ever fail.
		For default gating use `default_member_permissions` on the command.
	]]
	function applications.getGuildCommandPermissions(appId: Snowflake, guildId: Snowflake): { Types.GuildApplicationCommandPermissions }
		return http:get(`/applications/{appId}/guilds/{guildId}/commands/permissions`)
	end

	function applications.getCommandPermissions(
		appId: Snowflake,
		guildId: Snowflake,
		commandId: Snowflake
	): Types.GuildApplicationCommandPermissions
		return http:get(`/applications/{appId}/guilds/{guildId}/commands/{commandId}/permissions`)
	end

	--- Application-owned emoji: usable by the bot everywhere, with no guild slot.
	function applications.getEmojis(appId: Snowflake): { items: { Types.Emoji } }
		return http:get(`/applications/{appId}/emojis`)
	end

	function applications.getEmoji(appId: Snowflake, emojiId: Snowflake): Types.Emoji
		return http:get(`/applications/{appId}/emojis/{emojiId}`)
	end

	--- `image` is a `data:` URI. Over 256 KiB fails with a 400 that carries
	--- no JSON error code, so check the size before uploading.
	function applications.createEmoji(appId: Snowflake, name: string, image: string): Types.Emoji
		return http:post(`/applications/{appId}/emojis`, { body = { name = name, image = image } })
	end

	function applications.editEmoji(appId: Snowflake, emojiId: Snowflake, name: string): Types.Emoji
		return http:patch(`/applications/{appId}/emojis/{emojiId}`, { body = { name = name } })
	end

	function applications.deleteEmoji(appId: Snowflake, emojiId: Snowflake)
		http:delete(`/applications/{appId}/emojis/{emojiId}`)
	end

	function applications.getRoleConnectionMetadata(appId: Snowflake): { Types.RoleConnectionMetadata }
		return http:get(`/applications/{appId}/role-connections/metadata`)
	end

	--- Replaces the whole set. Discord allows at most 5 records.
	function applications.updateRoleConnectionMetadata(
		appId: Snowflake,
		records: { Types.RoleConnectionMetadata }
	): { Types.RoleConnectionMetadata }
		if #records > 5 then
			error(`an application can have at most 5 role connection metadata records, got {#records}`, 2)
		end
		return http:put(`/applications/{appId}/role-connections/metadata`, { body = records, list = true })
	end

	--- Lets an Activity's backend check that a launch is real before trusting it.
	function applications.getActivityInstance(appId: Snowflake, instanceId: string): Types.ActivityInstance
		return http:get(`/applications/{appId}/activity-instances/{Util.encodeComponent(instanceId)}`)
	end

	return applications
end

local function makeMonetization(http: Http.Http)
	local monetization = {}

	--- A subscription shows up as TWO SKUs; the one with `type` 5
	--- (SUBSCRIPTION) is the one to test and check entitlements against.
	function monetization.listSkus(appId: Snowflake): { Types.Sku }
		return http:get(`/applications/{appId}/skus`)
	end

	function monetization.listEntitlements(appId: Snowflake, query: Types.EntitlementQuery?): { Types.Entitlement }
		local wire: any = nil
		if query ~= nil then
			wire = table.clone(query) :: any
			-- This route reads a comma-joined list, not the repeated-key form
			-- `Util.query` produces for arrays.
			if query.sku_ids ~= nil then
				wire.sku_ids = table.concat(query.sku_ids, ",")
			end
		end
		return http:get(`/applications/{appId}/entitlements`, { query = wire })
	end

	function monetization.getEntitlement(appId: Snowflake, entitlementId: Snowflake): Types.Entitlement
		return http:get(`/applications/{appId}/entitlements/{entitlementId}`)
	end

	--- One-time consumable SKUs only.
	function monetization.consumeEntitlement(appId: Snowflake, entitlementId: Snowflake)
		http:post(`/applications/{appId}/entitlements/{entitlementId}/consume`)
	end

	--- The returned entitlement is partial (no dates; it never expires), and
	--- clients must reload before they see it.
	function monetization.createTestEntitlement(appId: Snowflake, options: Types.TestEntitlementCreate): Types.Entitlement
		return http:post(`/applications/{appId}/entitlements`, { body = options })
	end

	function monetization.deleteTestEntitlement(appId: Snowflake, entitlementId: Snowflake)
		http:delete(`/applications/{appId}/entitlements/{entitlementId}`)
	end

	--[[
		`userId` is a required argument rather than a query field: Discord
		only lets it be omitted on OAuth2 requests, and with a bot token the
		omission is a 400 that does not say what was missing.
	]]
	function monetization.listSubscriptions(
		skuId: Snowflake,
		userId: Snowflake,
		query: { before: Snowflake?, after: Snowflake?, limit: number? }?
	): { Types.Subscription }
		if type(userId) ~= "string" or userId == "" then
			error("listSubscriptions needs a user id when called with a bot token", 2)
		end
		local opts: { before: Snowflake?, after: Snowflake?, limit: number? } = query or {}
		return http:get(`/skus/{skuId}/subscriptions`, {
			query = { user_id = userId, before = opts.before, after = opts.after, limit = opts.limit },
		})
	end

	function monetization.getSubscription(skuId: Snowflake, subscriptionId: Snowflake): Types.Subscription
		return http:get(`/skus/{skuId}/subscriptions/{subscriptionId}`)
	end

	return monetization
end

--[[
	A callback's `data`, or nil when it is empty. A non-ephemeral defer
	builds `{ flags = nil }`, which `@std/json` would write as `"data": []`
	-- an array where Discord wants an object. Omitting `data` is what an
	empty one means anyway.
]]
local function callbackData(data: Types.InteractionCallbackData?): Types.InteractionCallbackData?
	if data ~= nil and next(data :: any) == nil then
		return nil
	end
	return data
end

--[[
	Every route here is an interaction endpoint, which Discord exempts from
	the global rate limit; `interaction = true` tells the transport so (see
	`Http.RequestOptions.interaction`). Callbacks carry their message under
	`data`, so that is where uploads' `attachments` go.
]]
local function makeInteractions(http: Http.Http)
	local interactions = {}

	--[[
		The first reply to an interaction.

		This route is unauthenticated -- the interaction token *is* the
		credential -- and it must land within 3 seconds of the interaction or
		Discord shows the user "application did not respond" and invalidates
		the token. Anything slower has to defer first.
	]]
	function interactions.createResponse(
		interactionId: Snowflake,
		token: string,
		type: number,
		data: Types.InteractionCallbackData?,
		files: { Http.File }?
	)
		http:post(`/interactions/{interactionId}/{token}/callback`, {
			body = { type = type, data = callbackData(data) },
			files = files,
			attachmentsPath = "data",
			noAuth = true,
			interaction = true,
		})
	end

	--[[
		`createResponse` with `?with_response=true`: the same callback, but
		Discord answers with what the reply created (the message, or the
		launched activity instance) instead of 204. A separate function
		rather than a flag so that each has one honest return type.
	]]
	function interactions.createResponseWithResult(
		interactionId: Snowflake,
		token: string,
		type: number,
		data: Types.InteractionCallbackData?,
		files: { Http.File }?
	): Types.InteractionCallbackResponse
		return http:post(`/interactions/{interactionId}/{token}/callback`, {
			body = { type = type, data = callbackData(data) },
			files = files,
			attachmentsPath = "data",
			query = { with_response = true },
			noAuth = true,
			interaction = true,
		})
	end

	function interactions.getOriginalResponse(appId: Snowflake, token: string): Types.Message
		return http:get(`/webhooks/{appId}/{token}/messages/@original`, { noAuth = true, interaction = true })
	end

	--[[
		Every field is optional: only the ones given change. New files are
		appended; to remove or replace existing ones, pass `attachments`
		listing the ones to keep (by id).
	]]
	function interactions.editOriginalResponse(appId: Snowflake, token: string, payload: Types.MessageInput): Types.Message
		local body, files = split(payload, EDIT)
		return http:patch(`/webhooks/{appId}/{token}/messages/@original`, {
			body = body,
			files = files,
			noAuth = true,
			interaction = true,
		})
	end

	function interactions.deleteOriginalResponse(appId: Snowflake, token: string)
		http:delete(`/webhooks/{appId}/{token}/messages/@original`, { noAuth = true, interaction = true })
	end

	function interactions.createFollowup(appId: Snowflake, token: string, payload: Types.MessageInput): Types.Message
		local body, files = split(payload)
		return http:post(`/webhooks/{appId}/{token}`, { body = body, files = files, noAuth = true, interaction = true })
	end

	function interactions.getFollowup(appId: Snowflake, token: string, messageId: Snowflake): Types.Message
		return http:get(`/webhooks/{appId}/{token}/messages/{messageId}`, { noAuth = true, interaction = true })
	end

	--[[
		Every field is optional: only the ones given change. New files are
		appended; to remove or replace existing ones, pass `attachments`
		listing the ones to keep (by id).
	]]
	function interactions.editFollowup(
		appId: Snowflake,
		token: string,
		messageId: Snowflake,
		payload: Types.MessageInput
	): Types.Message
		local body, files = split(payload, EDIT)
		return http:patch(`/webhooks/{appId}/{token}/messages/{messageId}`, {
			body = body,
			files = files,
			noAuth = true,
			interaction = true,
		})
	end

	function interactions.deleteFollowup(appId: Snowflake, token: string, messageId: Snowflake)
		http:delete(`/webhooks/{appId}/{token}/messages/{messageId}`, { noAuth = true, interaction = true })
	end

	return interactions
end

local function makeWebhooks(http: Http.Http)
	local webhooks = {}

	function webhooks.create(channelId: Snowflake, options: Types.WebhookCreate, reason: string?): Types.Webhook
		return http:post(`/channels/{channelId}/webhooks`, { body = options, reason = reason })
	end

	function webhooks.getChannelWebhooks(channelId: Snowflake): { Types.Webhook }
		return http:get(`/channels/{channelId}/webhooks`)
	end

	function webhooks.getGuildWebhooks(guildId: Snowflake): { Types.Webhook }
		return http:get(`/guilds/{guildId}/webhooks`)
	end

	--- Needs MANAGE_WEBHOOKS unless this application owns the webhook.
	function webhooks.get(webhookId: Snowflake): Types.Webhook
		return http:get(`/webhooks/{webhookId}`)
	end

	--- The token routes need no bot at all: the token is the credential.
	function webhooks.getWithToken(webhookId: Snowflake, token: string): Types.Webhook
		return http:get(`/webhooks/{webhookId}/{token}`, { noAuth = true })
	end

	function webhooks.edit(webhookId: Snowflake, patch: Types.WebhookPatch, reason: string?): Types.Webhook
		return http:patch(`/webhooks/{webhookId}`, { body = patch, reason = reason })
	end

	function webhooks.editWithToken(webhookId: Snowflake, token: string, patch: Types.WebhookPatch): Types.Webhook
		if patch.channel_id ~= nil then
			-- Discord refuses a move on the token route; say so here rather
			-- than let it look like the move silently did nothing.
			error("editWithToken cannot move a webhook: use webhooks.edit to change channel_id", 2)
		end
		return http:patch(`/webhooks/{webhookId}/{token}`, { body = patch, noAuth = true })
	end

	function webhooks.delete(webhookId: Snowflake, reason: string?)
		http:delete(`/webhooks/{webhookId}`, { reason = reason })
	end

	function webhooks.deleteWithToken(webhookId: Snowflake, token: string)
		http:delete(`/webhooks/{webhookId}/{token}`, { noAuth = true })
	end

	--[[
		`wait = true` makes Discord return the created message instead of 204.

		Webhooks not owned by an application drop `components` silently
		unless `with_components` is set. A forum or media channel also needs
		either `thread_id` here or `thread_name` in the payload, or the send
		fails.
	]]
	function webhooks.execute(
		webhookId: Snowflake,
		token: string,
		payload: Types.MessageInput,
		query: { wait: boolean?, thread_id: Snowflake?, with_components: boolean? }?
	): Types.Message?
		local body, files = split(payload)
		return http:post(`/webhooks/{webhookId}/{token}`, {
			body = body,
			files = files,
			query = query,
			noAuth = true,
		})
	end

	--- `threadId` is required when the message lives in a thread.
	function webhooks.getMessage(webhookId: Snowflake, token: string, messageId: Snowflake, threadId: Snowflake?): Types.Message
		return http:get(`/webhooks/{webhookId}/{token}/messages/{messageId}`, {
			query = { thread_id = threadId },
			noAuth = true,
		})
	end

	--[[
		Every field is optional: only the ones given change. New files are
		appended; to remove or replace existing ones, pass `attachments`
		listing the ones to keep (by id).
		Webhooks not owned by an application drop `components` unless
		`with_components` is set, as on `execute`.
	]]
	function webhooks.editMessage(
		webhookId: Snowflake,
		token: string,
		messageId: Snowflake,
		payload: Types.MessageInput,
		query: { thread_id: Snowflake?, with_components: boolean? }?
	): Types.Message
		local body, files = split(payload, EDIT)
		return http:patch(`/webhooks/{webhookId}/{token}/messages/{messageId}`, {
			body = body,
			files = files,
			query = query,
			noAuth = true,
		})
	end

	function webhooks.deleteMessage(webhookId: Snowflake, token: string, messageId: Snowflake, threadId: Snowflake?)
		http:delete(`/webhooks/{webhookId}/{token}/messages/{messageId}`, {
			query = { thread_id = threadId },
			noAuth = true,
		})
	end

	return webhooks
end

local function makeInvites(http: Http.Http)
	local invites = {}

	--- `guildScheduledEventId` attaches that event to the returned invite.
	function invites.get(code: string, withCounts: boolean?, guildScheduledEventId: Snowflake?): Types.Invite
		return http:get(`/invites/{Util.encodeComponent(code)}`, {
			query = { with_counts = withCounts, guild_scheduled_event_id = guildScheduledEventId },
		})
	end

	function invites.delete(code: string, reason: string?): Types.Invite
		return http:delete(`/invites/{Util.encodeComponent(code)}`, { reason = reason })
	end

	--[[
		Invite target users: an invite only the listed users can see and accept.

		Every route here needs the caller to be the inviter or hold
		MANAGE_GUILD. A CSV upload is processed in the background, so poll
		`getTargetUsersJobStatus` rather than assume it has finished.
	]]
	function invites.addTargetUser(code: string, userId: Snowflake)
		http:put(`/invites/{Util.encodeComponent(code)}/target-users/{userId}`)
	end

	function invites.removeTargetUser(code: string, userId: Snowflake)
		http:delete(`/invites/{Util.encodeComponent(code)}/target-users/{userId}`)
	end

	function invites.bulkAddTargetUsers(code: string, userIds: { Snowflake })
		checkCount("bulk-add target users", userIds, 1, 1000)
		http:post(`/invites/{Util.encodeComponent(code)}/target-users/bulk-add`, { body = { user_ids = userIds } })
	end

	function invites.bulkDeleteTargetUsers(code: string, userIds: { Snowflake })
		checkCount("bulk-delete target users", userIds, 1, 1000)
		http:post(`/invites/{Util.encodeComponent(code)}/target-users/bulk-delete`, { body = { user_ids = userIds } })
	end

	--- Replaces the whole list from a one-column CSV of user ids.
	function invites.updateTargetUsers(code: string, csv: Types.File)
		http:put(`/invites/{Util.encodeComponent(code)}/target-users`, {
			form = { files = { target_users_file = csv } },
		})
	end

	function invites.getTargetUsersJobStatus(code: string): Types.InviteTargetUsersJob
		return http:get(`/invites/{Util.encodeComponent(code)}/target-users/job-status`)
	end

	return invites
end

local function makeGateway(http: Http.Http)
	local gateway = {}

	--- Public gateway URL. No auth, no session limits -- rarely what you want.
	function gateway.get(): { url: string }
		return http:get("/gateway", { noAuth = true })
	end

	--- The bot-specific variant: recommended shard count and the remaining
	--- session starts. Worth checking before a mass restart, because
	--- exhausting session starts locks the bot out for hours.
	function gateway.getBot(): {
		url: string,
		shards: number,
		session_start_limit: { total: number, remaining: number, reset_after: number, max_concurrency: number },
	}
		return http:get("/gateway/bot")
	end
	return gateway
end

local function makePolls(http: Http.Http)
	local polls = {}

	function polls.getAnswerVoters(
		channelId: Snowflake,
		messageId: Snowflake,
		answerId: number,
		query: { after: Snowflake?, limit: number? }?
	): { users: { Types.User } }
		return http:get(`/channels/{channelId}/polls/{messageId}/answers/{answerId}`, { query = query })
	end

	function polls.endPoll(channelId: Snowflake, messageId: Snowflake): Types.Message
		return http:post(`/channels/{channelId}/polls/{messageId}/expire`)
	end
	return polls
end

----------------------------------------------------------------------------
-- CDN URLs
----------------------------------------------------------------------------

--[[
	Options for a CDN URL.

	`size` is a power of two from 16 to 4096. `format` is "png", "jpg",
	"jpeg", "webp" or "gif"; when omitted, an animated (`a_`) hash gets
	"gif" and anything else "png". Set `animated = false` to force a still
	frame of an animated hash.
]]
export type CdnOptions = {
	size: number?,
	format: string?,
	animated: boolean?,
}

local FORMATS = { png = true, jpg = true, jpeg = true, webp = true, gif = true }

-- Discord only resizes to powers of two; anything else is a 400.
local function checkSize(size: number?, level: number)
	if size == nil then
		return
	end
	local valid = size >= 16 and size <= 4096 and math.floor(size) == size
	if valid then
		local n = size
		while n > 1 and n % 2 == 0 do
			n //= 2
		end
		valid = n == 1
	end
	if not valid then
		error(`CDN size must be a power of two from 16 to 4096, got {size}`, level + 1)
	end
end

--[[
	`(id >> 22) % 6` without letting the id near a float.

	A snowflake is up to 64 bits and a double holds 53, so `tonumber(id)`
	rounds -- and a rounding that crosses a multiple of 2^22 changes the
	quotient, handing some users the wrong default avatar. Long division on
	the decimal string (as `@discord/snowflake` does) keeps it exact: the
	quotient is only ~42 bits.
]]
local function shiftRight22(id: string): number
	local quotient = 0
	local remainder = 0
	for index = 1, #id do
		local digit = string.byte(id, index) - 48
		if digit < 0 or digit > 9 then
			error(`not a snowflake: {id}`, 4)
		end
		local current = remainder * 10 + digit
		quotient = quotient * 10 + current // 4194304
		remainder = current % 4194304
	end
	return quotient
end

local function makeCdn()
	local cdn = {}
	local BASE = Const.CDN_BASE

	local function build(path: string, hash: string, options: CdnOptions?, animatable: boolean): string
		local opts: CdnOptions = options or {}
		checkSize(opts.size, 3)
		local animated = animatable and string.sub(hash, 1, 2) == "a_" and opts.animated ~= false
		local format = opts.format or (if animated then "gif" else "png")
		if not FORMATS[format] then
			error(`unknown CDN format "{format}": use png, jpg, webp or gif`, 3)
		end
		if format == "gif" and not animated then
			error("gif is only available for animated (a_) hashes", 3)
		end
		-- Animated WebP has to be asked for explicitly; the bare extension
		-- serves the first frame.
		local query = { size = opts.size, animated = if animated and format == "webp" then true else nil }
		return `{BASE}/{path}/{hash}.{format}{Util.query(query)}`
	end

	--[[
		The default avatar index, for users with no avatar hash.

		Migrated users (discriminator "0" or absent) use `(id >> 22) % 6`;
		legacy ones use `discriminator % 5`. Default avatars ignore `size`.
	]]
	function cdn.defaultAvatar(user: { id: Snowflake, discriminator: string?, [string]: any }): string
		local discriminator = user.discriminator
		local index = if discriminator ~= nil and discriminator ~= "0" and discriminator ~= ""
			then (tonumber(discriminator) or 0) % 5
			else shiftRight22(user.id) % 6
		return `{BASE}/embed/avatars/{index}.png`
	end

	--- The user's avatar, falling back to their default avatar when unset.
	function cdn.userAvatar(
		user: { id: Snowflake, avatar: string?, discriminator: string?, [string]: any },
		options: CdnOptions?
	): string
		local avatar = user.avatar
		if avatar == nil then
			return cdn.defaultAvatar(user)
		end
		return build(`avatars/{user.id}`, avatar, options, true)
	end

	function cdn.userBanner(userId: Snowflake, hash: string, options: CdnOptions?): string
		return build(`banners/{userId}`, hash, options, true)
	end

	--- A per-guild avatar (`member.avatar`), which overrides the user's own.
	function cdn.memberAvatar(guildId: Snowflake, userId: Snowflake, hash: string, options: CdnOptions?): string
		return build(`guilds/{guildId}/users/{userId}/avatars`, hash, options, true)
	end

	function cdn.memberBanner(guildId: Snowflake, userId: Snowflake, hash: string, options: CdnOptions?): string
		return build(`guilds/{guildId}/users/{userId}/banners`, hash, options, true)
	end

	function cdn.guildIcon(guildId: Snowflake, hash: string, options: CdnOptions?): string
		return build(`icons/{guildId}`, hash, options, true)
	end

	function cdn.guildBanner(guildId: Snowflake, hash: string, options: CdnOptions?): string
		return build(`banners/{guildId}`, hash, options, true)
	end

	function cdn.guildSplash(guildId: Snowflake, hash: string, options: CdnOptions?): string
		return build(`splashes/{guildId}`, hash, options, false)
	end

	function cdn.guildDiscoverySplash(guildId: Snowflake, hash: string, options: CdnOptions?): string
		return build(`discovery-splashes/{guildId}`, hash, options, false)
	end

	function cdn.roleIcon(roleId: Snowflake, hash: string, options: CdnOptions?): string
		return build(`role-icons/{roleId}`, hash, options, false)
	end

	function cdn.applicationIcon(appId: Snowflake, hash: string, options: CdnOptions?): string
		return build(`app-icons/{appId}`, hash, options, false)
	end

	function cdn.scheduledEventCover(eventId: Snowflake, hash: string, options: CdnOptions?): string
		return build(`guild-events/{eventId}`, hash, options, false)
	end

	--[[
		A custom emoji. Emoji carry an `animated` flag rather than an `a_`
		hash, so pass it. The default format is WebP, not PNG: Discord asks
		for it because emoji uploaded as WebP or AVIF do not convert cleanly,
		and animated ones come back as animated WebP.
	]]
	function cdn.emoji(emojiId: Snowflake, animated: boolean?, options: CdnOptions?): string
		local opts: CdnOptions = options or {}
		checkSize(opts.size, 2)
		local format = opts.format or "webp"
		if not FORMATS[format] then
			error(`unknown CDN format "{format}": use png, jpg, webp or gif`, 2)
		end
		if format == "gif" and not animated then
			error("gif is only available for animated emoji", 2)
		end
		local query = { size = opts.size, animated = if animated and format == "webp" then true else nil }
		return `{BASE}/emojis/{emojiId}.{format}{Util.query(query)}`
	end

	--[[
		A sticker, in the only format it exists in: PNG for PNG/APNG, Lottie
		JSON for LOTTIE, and GIF -- which lives on media.discordapp.net, not
		the CDN host. Stickers ignore `size`.
	]]
	function cdn.sticker(sticker: { id: Snowflake, format_type: number?, [string]: any }): string
		local kind = sticker.format_type
		if kind == Const.StickerFormatType.GIF then
			return `https://media.discordapp.net/stickers/{sticker.id}.gif`
		elseif kind == Const.StickerFormatType.LOTTIE then
			return `{BASE}/stickers/{sticker.id}.json`
		end
		return `{BASE}/stickers/{sticker.id}.png`
	end

	function cdn.stickerPackBanner(bannerAssetId: Snowflake, options: CdnOptions?): string
		-- Every pack banner lives under Discord's own sticker application id.
		return build("app-assets/710982414301790216/store", bannerAssetId, options, false)
	end

	return cdn
end

--- Pure URL builders; also reachable as `api.cdn` on an instance.
Api.cdn = makeCdn()

--[[
	The namespaces, named.

	Each is `typeof` its own factory rather than a hand-written list of
	ninety signatures: the factory IS the declaration, so a route added
	below shows up here with no second place to keep in step.
]]
export type Channels = typeof(makeChannels((nil :: any) :: Http.Http))
export type Guilds = typeof(makeGuilds((nil :: any) :: Http.Http))
export type Stickers = typeof(makeStickers((nil :: any) :: Http.Http))
export type Soundboard = typeof(makeSoundboard((nil :: any) :: Http.Http))
export type StageInstances = typeof(makeStageInstances((nil :: any) :: Http.Http))
export type Voice = typeof(makeVoice((nil :: any) :: Http.Http))
export type Users = typeof(makeUsers((nil :: any) :: Http.Http))
export type Applications = typeof(makeApplications((nil :: any) :: Http.Http))
export type Monetization = typeof(makeMonetization((nil :: any) :: Http.Http))
export type Interactions = typeof(makeInteractions((nil :: any) :: Http.Http))
export type Webhooks = typeof(makeWebhooks((nil :: any) :: Http.Http))
export type Invites = typeof(makeInvites((nil :: any) :: Http.Http))
export type Gateway = typeof(makeGateway((nil :: any) :: Http.Http))
export type Polls = typeof(makePolls((nil :: any) :: Http.Http))
export type Cdn = typeof(makeCdn())

export type Api = {
	http: Http.Http,
	channels: Channels,
	guilds: Guilds,
	stickers: Stickers,
	soundboard: Soundboard,
	stageInstances: StageInstances,
	voice: Voice,
	users: Users,
	applications: Applications,
	monetization: Monetization,
	interactions: Interactions,
	webhooks: Webhooks,
	invites: Invites,
	gateway: Gateway,
	polls: Polls,
	cdn: Cdn,
}

function Api.new(http: Http.Http): Api
	return {
		http = http,
		channels = makeChannels(http),
		guilds = makeGuilds(http),
		stickers = makeStickers(http),
		soundboard = makeSoundboard(http),
		stageInstances = makeStageInstances(http),
		voice = makeVoice(http),
		users = makeUsers(http),
		applications = makeApplications(http),
		monetization = makeMonetization(http),
		interactions = makeInteractions(http),
		webhooks = makeWebhooks(http),
		invites = makeInvites(http),
		gateway = makeGateway(http),
		polls = makePolls(http),
		cdn = Api.cdn,
	}
end

return Api
