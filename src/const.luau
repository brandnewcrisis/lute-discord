--!strict
--[[
	Protocol constants for the Discord API (v10).

	Everything here is data lifted from Discord's documentation: opcodes, close
	codes, bit positions, enum values. It is kept in one place so the rest of
	the library never writes a bare magic number, and so bumping the API
	version is a one-line change.

	Permission flags are stored as BIT POSITIONS, not as values. The highest
	permission is currently bit 52 and Discord keeps adding more; once bit 53
	arrives a Luau number can no longer hold the mask exactly, so permissions
	are carried as a 64-bit pair (see `@discord/bitfield`) and a bit position
	is the only representation that works for both today and then.
]]

local Const = {}

Const.API_VERSION = 10
Const.API_BASE = "https://discord.com/api/v10"
Const.CDN_BASE = "https://cdn.discordapp.com"
Const.GATEWAY_QUERY = "?v=10&encoding=json"

-- The library's own version, and where it lives. Both feed the User-Agent.
Const.VERSION = "0.4.0"
Const.REPOSITORY_URL = "https://github.com/brandnewcrisis/lute-discord"

-- Sent with every REST call. Discord asks for this exact shape and will
-- rate-limit or block clients that send something unrecognisable.
Const.USER_AGENT = `DiscordBot ({Const.REPOSITORY_URL}, {Const.VERSION})`

-- Gateway opcodes (payload `op`).
Const.Op = table.freeze({
	DISPATCH = 0,
	HEARTBEAT = 1,
	IDENTIFY = 2,
	PRESENCE_UPDATE = 3,
	VOICE_STATE_UPDATE = 4,
	RESUME = 6,
	RECONNECT = 7,
	REQUEST_GUILD_MEMBERS = 8,
	INVALID_SESSION = 9,
	HELLO = 10,
	HEARTBEAT_ACK = 11,
	REQUEST_SOUNDBOARD_SOUNDS = 31,
})

--[[
	Gateway close codes.

	The split that matters is `RESUMABLE`: anything not listed there is either
	fatal (bad token, intents you were not granted) or requires a fresh
	IDENTIFY rather than a RESUME. Reconnecting blindly on 4004 produces an
	infinite auth-failure loop, which is the classic way a hand-rolled gateway
	client gets a token flagged.
]]
Const.CloseCode = table.freeze({
	UNKNOWN_ERROR = 4000,
	UNKNOWN_OPCODE = 4001,
	DECODE_ERROR = 4002,
	NOT_AUTHENTICATED = 4003,
	AUTHENTICATION_FAILED = 4004,
	ALREADY_AUTHENTICATED = 4005,
	INVALID_SEQ = 4007,
	RATE_LIMITED = 4008,
	SESSION_TIMED_OUT = 4009,
	INVALID_SHARD = 4010,
	SHARDING_REQUIRED = 4011,
	INVALID_API_VERSION = 4012,
	INVALID_INTENTS = 4013,
	DISALLOWED_INTENTS = 4014,
})

--[[
	Discord's documented close codes after which the same session can be
	resumed, plus 1005 and 1006 -- the runtime's "no close frame arrived",
	which is a dropped connection, and Discord says to resume after a
	disconnect that carries no close code.

	Not the same list as Discord's "reconnect: true" column. 4007 (invalid
	seq) and 4009 (session timed out) say reconnect AND start a new session:
	resuming after 4007 sends the same bad sequence and earns another 4007,
	forever.

	Informational: the shard decides with `SESSION_ENDING_CLOSE_CODES`, so a
	code in neither table (a 1011 from a proxy, say) is resumed. If Discord
	did end the session, the RESUME is answered with INVALID_SESSION and
	the shard re-identifies, losing nothing but the attempt.
]]
Const.RESUMABLE_CLOSE_CODES = table.freeze({
	[1005] = true,
	[1006] = true,
	[4000] = true,
	[4001] = true,
	[4002] = true,
	[4003] = true,
	[4005] = true,
	[4008] = true,
})

--[[
	Server close codes after which the session is gone and the next
	connection must IDENTIFY. 4007 and 4009 say so outright; a server that
	closes with 1000 or 1001 has invalidated the session, exactly as our
	own 1000/1001 close would. Fatal codes (below) end the shard instead.
]]
Const.SESSION_ENDING_CLOSE_CODES = table.freeze({
	[1000] = true,
	[1001] = true,
	[4007] = true,
	[4009] = true,
})

-- Close codes that no amount of reconnecting will fix.
Const.FATAL_CLOSE_CODES = table.freeze({
	[4004] = "authentication failed -- the bot token is wrong or has been reset",
	[4010] = "invalid shard -- shardId must be less than shardCount",
	[4011] = "sharding required -- this bot is in too many guilds for one shard",
	[4012] = "invalid API version",
	[4013] = "invalid intents -- an unknown intent bit was requested",
	[4014] = "disallowed intents -- enable the privileged intents you asked for "
		.. "under Bot > Privileged Gateway Intents in the developer portal",
})

--[[
	Gateway intents, as bit positions.

	The three privileged ones are listed separately because asking for them
	without ticking the box in the developer portal closes the socket with
	4014 rather than failing softly -- a bot that "connects fine locally and
	dies in production" is nearly always this.
]]
Const.IntentBits = table.freeze({
	guilds = 0,
	guildMembers = 1,
	guildModeration = 2,
	guildExpressions = 3,
	guildIntegrations = 4,
	guildWebhooks = 5,
	guildInvites = 6,
	guildVoiceStates = 7,
	guildPresences = 8,
	guildMessages = 9,
	guildMessageReactions = 10,
	guildMessageTyping = 11,
	directMessages = 12,
	directMessageReactions = 13,
	directMessageTyping = 14,
	messageContent = 15,
	guildScheduledEvents = 16,
	autoModerationConfiguration = 20,
	autoModerationExecution = 21,
	guildMessagePolls = 24,
	directMessagePolls = 25,
})

Const.PRIVILEGED_INTENTS = table.freeze({
	guildMembers = true,
	guildPresences = true,
	messageContent = true,
})

-- Permission flags, as bit positions. See the module comment.
Const.PermissionBits = table.freeze({
	createInstantInvite = 0,
	kickMembers = 1,
	banMembers = 2,
	administrator = 3,
	manageChannels = 4,
	manageGuild = 5,
	addReactions = 6,
	viewAuditLog = 7,
	prioritySpeaker = 8,
	stream = 9,
	viewChannel = 10,
	sendMessages = 11,
	sendTtsMessages = 12,
	manageMessages = 13,
	embedLinks = 14,
	attachFiles = 15,
	readMessageHistory = 16,
	mentionEveryone = 17,
	useExternalEmojis = 18,
	viewGuildInsights = 19,
	connect = 20,
	speak = 21,
	muteMembers = 22,
	deafenMembers = 23,
	moveMembers = 24,
	useVad = 25,
	changeNickname = 26,
	manageNicknames = 27,
	manageRoles = 28,
	manageWebhooks = 29,
	manageGuildExpressions = 30,
	useApplicationCommands = 31,
	requestToSpeak = 32,
	manageEvents = 33,
	manageThreads = 34,
	createPublicThreads = 35,
	createPrivateThreads = 36,
	useExternalStickers = 37,
	sendMessagesInThreads = 38,
	useEmbeddedActivities = 39,
	moderateMembers = 40,
	viewCreatorMonetizationAnalytics = 41,
	useSoundboard = 42,
	createGuildExpressions = 43,
	createEvents = 44,
	useExternalSounds = 45,
	sendVoiceMessages = 46,
	setVoiceChannelStatus = 48,
	sendPolls = 49,
	useExternalApps = 50,
	-- Split from manageMessages; since 2026-02-23 manageMessages alone no
	-- longer lets a bot pin.
	pinMessages = 51,
	bypassSlowmode = 52,
})

-- Message flags (bit positions).
Const.MessageFlagBits = table.freeze({
	crossposted = 0,
	isCrosspost = 1,
	suppressEmbeds = 2,
	sourceMessageDeleted = 3,
	urgent = 4,
	hasThread = 5,
	ephemeral = 6,
	loading = 7,
	suppressNotifications = 12,
	isVoiceMessage = 13,
	isComponentsV2 = 15,
})

Const.MessageFlag = table.freeze({
	SUPPRESS_EMBEDS = 4,
	EPHEMERAL = 64,
	SUPPRESS_NOTIFICATIONS = 4096,
	IS_COMPONENTS_V2 = 32768,
})

Const.InteractionType = table.freeze({
	PING = 1,
	APPLICATION_COMMAND = 2,
	MESSAGE_COMPONENT = 3,
	APPLICATION_COMMAND_AUTOCOMPLETE = 4,
	MODAL_SUBMIT = 5,
})

Const.InteractionCallback = table.freeze({
	PONG = 1,
	CHANNEL_MESSAGE_WITH_SOURCE = 4,
	DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE = 5,
	DEFERRED_UPDATE_MESSAGE = 6,
	UPDATE_MESSAGE = 7,
	APPLICATION_COMMAND_AUTOCOMPLETE_RESULT = 8,
	MODAL = 9,
	PREMIUM_REQUIRED = 10,
	LAUNCH_ACTIVITY = 12,
})

Const.CommandType = table.freeze({
	CHAT_INPUT = 1,
	USER = 2,
	MESSAGE = 3,
	PRIMARY_ENTRY_POINT = 4,
})

Const.OptionType = table.freeze({
	SUB_COMMAND = 1,
	SUB_COMMAND_GROUP = 2,
	STRING = 3,
	INTEGER = 4,
	BOOLEAN = 5,
	USER = 6,
	CHANNEL = 7,
	ROLE = 8,
	MENTIONABLE = 9,
	NUMBER = 10,
	ATTACHMENT = 11,
})

Const.ComponentType = table.freeze({
	ACTION_ROW = 1,
	BUTTON = 2,
	STRING_SELECT = 3,
	TEXT_INPUT = 4,
	USER_SELECT = 5,
	ROLE_SELECT = 6,
	MENTIONABLE_SELECT = 7,
	CHANNEL_SELECT = 8,
	-- Components V2 (messages sent with IS_COMPONENTS_V2).
	SECTION = 9,
	TEXT_DISPLAY = 10,
	THUMBNAIL = 11,
	MEDIA_GALLERY = 12,
	FILE = 13,
	SEPARATOR = 14,
	CONTAINER = 17,
	-- Modal-only. 15, 16 and 20 are unassigned in the public docs.
	LABEL = 18,
	FILE_UPLOAD = 19,
	RADIO_GROUP = 21,
	CHECKBOX_GROUP = 22,
	CHECKBOX = 23,
})

Const.SeparatorSpacing = table.freeze({
	SMALL = 1,
	LARGE = 2,
})

Const.ButtonStyle = table.freeze({
	PRIMARY = 1,
	SECONDARY = 2,
	SUCCESS = 3,
	DANGER = 4,
	LINK = 5,
	PREMIUM = 6,
})

Const.TextInputStyle = table.freeze({
	SHORT = 1,
	PARAGRAPH = 2,
})

Const.ChannelType = table.freeze({
	GUILD_TEXT = 0,
	DM = 1,
	GUILD_VOICE = 2,
	GROUP_DM = 3,
	GUILD_CATEGORY = 4,
	GUILD_ANNOUNCEMENT = 5,
	ANNOUNCEMENT_THREAD = 10,
	PUBLIC_THREAD = 11,
	PRIVATE_THREAD = 12,
	GUILD_STAGE_VOICE = 13,
	GUILD_DIRECTORY = 14,
	GUILD_FORUM = 15,
	GUILD_MEDIA = 16,
})

Const.OverwriteType = table.freeze({
	ROLE = 0,
	MEMBER = 1,
})

Const.ActivityType = table.freeze({
	PLAYING = 0,
	STREAMING = 1,
	LISTENING = 2,
	WATCHING = 3,
	CUSTOM = 4,
	COMPETING = 5,
})

-- `type` on the get-reactions route: super reactions are BURST.
Const.ReactionType = table.freeze({
	NORMAL = 0,
	BURST = 1,
})

Const.StickerType = table.freeze({
	STANDARD = 1,
	GUILD = 2,
})

Const.StickerFormatType = table.freeze({
	PNG = 1,
	APNG = 2,
	LOTTIE = 3,
	GIF = 4,
})

-- PUBLIC is deprecated; GUILD_ONLY is the default.
Const.StagePrivacyLevel = table.freeze({
	PUBLIC = 1,
	GUILD_ONLY = 2,
})

Const.CommandPermissionType = table.freeze({
	ROLE = 1,
	USER = 2,
	CHANNEL = 3,
})

Const.RoleConnectionMetadataType = table.freeze({
	INTEGER_LESS_THAN_OR_EQUAL = 1,
	INTEGER_GREATER_THAN_OR_EQUAL = 2,
	INTEGER_EQUAL = 3,
	INTEGER_NOT_EQUAL = 4,
	DATETIME_LESS_THAN_OR_EQUAL = 5,
	DATETIME_GREATER_THAN_OR_EQUAL = 6,
	BOOLEAN_EQUAL = 7,
	BOOLEAN_NOT_EQUAL = 8,
})

Const.SkuType = table.freeze({
	DURABLE = 2,
	CONSUMABLE = 3,
	SUBSCRIPTION = 5,
	SUBSCRIPTION_GROUP = 6,
})

Const.EntitlementType = table.freeze({
	PURCHASE = 1,
	PREMIUM_SUBSCRIPTION = 2,
	DEVELOPER_GIFT = 3,
	TEST_MODE_PURCHASE = 4,
	FREE_PURCHASE = 5,
	USER_GIFT = 6,
	PREMIUM_PURCHASE = 7,
	APPLICATION_SUBSCRIPTION = 8,
})

-- `owner_type` when creating a test entitlement.
Const.EntitlementOwnerType = table.freeze({
	GUILD = 1,
	USER = 2,
})

Const.SubscriptionStatus = table.freeze({
	ACTIVE = 0,
	INACTIVE = 1,
	ENDING = 2,
})

-- Discord's brand palette plus the handful of colours embeds actually use.
Const.Color = table.freeze({
	BLURPLE = 0x5865F2,
	GREEN = 0x57F287,
	YELLOW = 0xFEE75C,
	FUCHSIA = 0xEB459E,
	RED = 0xED4245,
	WHITE = 0xFFFFFF,
	BLACK = 0x000000,
	GREY = 0x99AAB5,
	DARK = 0x2B2D31,
})

-- The epoch snowflake timestamps count from (2015-01-01T00:00:00Z, in ms).
Const.DISCORD_EPOCH = 1420070400000

return table.freeze(Const)
