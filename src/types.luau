--!strict
--[[
	Shapes for the objects Discord sends back, and for the bodies it accepts.

	These are deliberately partial. Discord's payloads carry dozens of fields
	per object, most of them irrelevant to a bot and several of them
	undocumented and unstable, so modelling every one would be a maintenance
	tax that buys nothing. Each type here covers the fields worth having
	autocomplete for and leaves the rest reachable -- every type is open, so
	`message.position` still reads fine, just untyped.

	Ids are `string` everywhere and must stay that way: a 64-bit snowflake
	does not survive a round trip through a Luau number.

	The file is in four parts: primitives, the objects Discord sends, the
	bodies it accepts, and the gateway payloads.
]]

export type Snowflake = string

--- What a slash command option can carry. `mentionable` and the id-bearing
--- types all arrive as snowflake strings.
export type OptionValue = string | number | boolean

--[[
	A `T`, or a builder that yields one.

	`@discord/embed` and `@discord/commands` return builder objects, and
	`Payload.toJSON` unwraps anything with a `toJSON` method, so the two are
	interchangeable everywhere a payload is accepted. This is how the types
	say that without every call site having to unwrap by hand.
]]
export type Buildable<T> = T | { toJSON: (any) -> T }

--- A file to upload. Files travel as multipart parts rather than as a JSON
--- field, so `@discord/http` splits them out of the body it is given.
export type File = {
	name: string,
	data: string | buffer,
	contentType: string?,
	description: string?,
}

----------------------------------------------------------------------------
-- Objects Discord sends
----------------------------------------------------------------------------

export type User = {
	id: Snowflake,
	username: string,
	discriminator: string?,
	global_name: string?,
	avatar: string?,
	bot: boolean?,
	system: boolean?,
	banner: string?,
	accent_color: number?,
	public_flags: number?,
	[string]: any,
}

export type Member = {
	user: User?,
	nick: string?,
	avatar: string?,
	roles: { Snowflake },
	joined_at: string,
	premium_since: string?,
	deaf: boolean?,
	mute: boolean?,
	pending: boolean?,
	--- ISO timestamp; a member is timed out while this is in the future.
	communication_disabled_until: string?,
	--- Present only on interaction payloads: the caller's computed permissions
	--- in that channel, already resolved by Discord. Cheaper and more correct
	--- than recomputing, when it is there.
	permissions: string?,
	[string]: any,
}

export type Role = {
	id: Snowflake,
	name: string,
	color: number,
	hoist: boolean,
	position: number,
	permissions: string,
	managed: boolean,
	mentionable: boolean,
	icon: string?,
	unicode_emoji: string?,
	[string]: any,
}

export type Overwrite = {
	id: Snowflake,
	--- 0 = role, 1 = member.
	type: number,
	allow: string,
	deny: string,
}

export type Channel = {
	id: Snowflake,
	type: number,
	guild_id: Snowflake?,
	name: string?,
	topic: string?,
	nsfw: boolean?,
	position: number?,
	parent_id: Snowflake?,
	permission_overwrites: { Overwrite }?,
	rate_limit_per_user: number?,
	bitrate: number?,
	user_limit: number?,
	recipients: { User }?,
	[string]: any,
}

export type Emoji = {
	id: Snowflake?,
	name: string?,
	animated: boolean?,
	[string]: any,
}

export type Sticker = {
	id: Snowflake,
	name: string,
	description: string?,
	tags: string?,
	type: number?,
	format_type: number?,
	guild_id: Snowflake?,
	available: boolean?,
	[string]: any,
}

export type Guild = {
	id: Snowflake,
	name: string,
	icon: string?,
	banner: string?,
	description: string?,
	owner_id: Snowflake,
	roles: { Role }?,
	emojis: { Emoji }?,
	stickers: { Sticker }?,
	features: { string }?,
	member_count: number?,
	premium_tier: number?,
	premium_subscription_count: number?,
	preferred_locale: string?,
	verification_level: number?,
	[string]: any,
}

export type Attachment = {
	id: Snowflake,
	filename: string,
	size: number,
	url: string,
	proxy_url: string,
	content_type: string?,
	width: number?,
	height: number?,
	description: string?,
	[string]: any,
}

export type EmbedField = { name: string, value: string, inline: boolean? }

export type Embed = {
	title: string?,
	type: string?,
	description: string?,
	url: string?,
	timestamp: string?,
	color: number?,
	footer: { text: string, icon_url: string? }?,
	image: { url: string }?,
	thumbnail: { url: string }?,
	author: { name: string, url: string?, icon_url: string? }?,
	fields: { EmbedField }?,
}

export type SelectOption = {
	label: string,
	value: string,
	description: string?,
	emoji: Emoji?,
	default: boolean?,
}

--- A pre-selected entry in a user, role, mentionable or channel select.
export type SelectDefaultValue = {
	id: Snowflake,
	--- "user", "role" or "channel".
	type: string,
}

--- Media referenced by a thumbnail, gallery item or file. Only `url` is
--- settable; Discord fills in the rest on the message it sends back.
export type UnfurledMedia = {
	--- A direct link, or `attachment://<filename>` for an upload.
	url: string,
	proxy_url: string?,
	width: number?,
	height: number?,
	content_type: string?,
	attachment_id: Snowflake?,
	[string]: any,
}

export type MediaGalleryItem = {
	media: UnfurledMedia,
	description: string?,
	spoiler: boolean?,
}

--[[
	A message or modal component on the wire.

	Discord's components are a tagged union on `type` -- twenty kinds now,
	from buttons to containers to modal checkboxes -- but they are modelled
	here as one open struct rather than a Luau union. The tradeoff was
	re-weighed for Components V2 and came out the same way: the builders in
	`@discord/components` validate each shape at construction, which is
	where a mistake can be reported against the line that made it, while a
	union would force a narrowing cast at every site that walks a tree
	(`setDisabled`, the paginator, anything reading a `custom_id`), and V2
	trees nest three deep. The cost is that the type admits nonsense such as
	a text display with a `url`; the constructors and `Components.validate`
	are what refuse it.
]]
export type Component = {
	type: number,
	--- Optional 32-bit identifier, unique within the message. Discord
	--- assigns one when omitted.
	id: number?,
	style: number?,
	label: string?,
	emoji: Emoji?,
	custom_id: string?,
	url: string?,
	--- Premium buttons only.
	sku_id: Snowflake?,
	disabled: boolean?,
	--- String selects, radio groups and checkbox groups.
	options: { SelectOption }?,
	placeholder: string?,
	min_values: number?,
	max_values: number?,
	--- User, role, mentionable and channel selects.
	default_values: { SelectDefaultValue }?,
	--- Text inputs.
	min_length: number?,
	max_length: number?,
	--- Anything answerable in a modal.
	required: boolean?,
	value: string?,
	--- Channel selects only.
	channel_types: { number }?,
	--- File uploads only: `image`, `video`, `audio` or `.ext`.
	file_types: { string }?,
	--- Checkboxes only.
	default: boolean?,
	--- Action rows, sections and containers.
	components: { Component }?,
	--- Sections only: the button or thumbnail beside the text.
	accessory: Component?,
	--- Labels only: the input being labelled.
	component: Component?,
	--- Label description, or thumbnail alt text.
	description: string?,
	--- Text displays only.
	content: string?,
	--- Thumbnails only.
	media: UnfurledMedia?,
	--- Media galleries only.
	items: { MediaGalleryItem }?,
	--- File components only; always an `attachment://` reference.
	file: UnfurledMedia?,
	--- Thumbnails, files and containers.
	spoiler: boolean?,
	--- Separators only.
	divider: boolean?,
	spacing: number?,
	--- Containers only.
	accent_color: number?,
	[string]: any,
}

--- An action row. Once the only thing allowed at the top level of a
--- message; under Components V2 it is one top-level kind among several,
--- so this is now just a name for readability.
export type ActionRow = Component

--- A modal form. Not a `Component` -- it is the body of a MODAL interaction
--- response, and carries no `type`. Its children are labels, text displays,
--- or (legacy) action rows each holding one text input.
export type Modal = {
	custom_id: string,
	title: string,
	components: { Component },
	[string]: any,
}

--[[
	One component as it comes BACK in a modal submission.

	Not a `Component`: Discord answers with a different, thinner shape, and
	`value` changes type with the kind -- a string from a text input or a
	radio group, a boolean from a checkbox. Selects, checkbox groups and
	file uploads answer in `values` instead. Rows and labels carry their
	child in `components` and `component` respectively.
]]
export type SubmittedComponent = {
	type: number?,
	id: number?,
	custom_id: string?,
	value: (string | boolean)?,
	values: { string }?,
	components: { SubmittedComponent }?,
	component: SubmittedComponent?,
	[string]: any,
}

export type Reaction = {
	count: number,
	me: boolean?,
	emoji: Emoji,
	burst_count: number?,
	[string]: any,
}

export type PollMedia = {
	text: string?,
	emoji: Emoji?,
	[string]: any,
}

export type PollAnswer = {
	--- Assigned by Discord on a poll it sends back; omitted when creating one.
	answer_id: number?,
	poll_media: PollMedia,
	[string]: any,
}

export type PollResults = {
	is_finalized: boolean,
	answer_counts: { { id: number, count: number, me_voted: boolean } },
	[string]: any,
}

export type Poll = {
	question: PollMedia,
	answers: { PollAnswer },
	--- Hours the poll stays open. Creation only.
	duration: number?,
	allow_multiselect: boolean?,
	layout_type: number?,
	--- Set by Discord on a poll it sends back.
	expiry: string?,
	results: PollResults?,
	[string]: any,
}

export type MessageReference = {
	message_id: Snowflake?,
	channel_id: Snowflake?,
	guild_id: Snowflake?,
	--- 0 = reply, 1 = forward.
	type: number?,
	fail_if_not_exists: boolean?,
}

export type Message = {
	id: Snowflake,
	channel_id: Snowflake,
	guild_id: Snowflake?,
	author: User,
	member: Member?,
	content: string,
	timestamp: string,
	edited_timestamp: string?,
	tts: boolean,
	mention_everyone: boolean,
	mentions: { User },
	mention_roles: { Snowflake },
	attachments: { Attachment },
	embeds: { Embed },
	reactions: { Reaction }?,
	pinned: boolean,
	webhook_id: Snowflake?,
	type: number,
	flags: number?,
	referenced_message: Message?,
	components: { Component }?,
	poll: Poll?,
	[string]: any,
}

export type Invite = {
	code: string,
	guild: Guild?,
	channel: Channel?,
	inviter: User?,
	target_type: number?,
	target_user: User?,
	approximate_presence_count: number?,
	approximate_member_count: number?,
	expires_at: string?,
	uses: number?,
	max_uses: number?,
	max_age: number?,
	temporary: boolean?,
	created_at: string?,
	[string]: any,
}

--- What following an announcement channel returns: the crosspost target and
--- the webhook Discord created to deliver into it.
export type FollowedChannel = {
	channel_id: Snowflake,
	webhook_id: Snowflake,
	[string]: any,
}

export type Ban = {
	reason: string?,
	user: User,
	[string]: any,
}

export type Webhook = {
	id: Snowflake,
	type: number,
	guild_id: Snowflake?,
	channel_id: Snowflake?,
	user: User?,
	name: string?,
	avatar: string?,
	--- Incoming webhooks only, and only when fetched with the bot token.
	token: string?,
	application_id: Snowflake?,
	url: string?,
	[string]: any,
}

export type ThreadMember = {
	--- The thread id. Absent on the member objects inside a GUILD_CREATE.
	id: Snowflake?,
	user_id: Snowflake?,
	join_timestamp: string,
	flags: number,
	member: Member?,
	[string]: any,
}

--- What the "list threads" routes return: the threads plus this bot's
--- membership of each.
export type ThreadList = {
	threads: { Channel },
	members: { ThreadMember },
	has_more: boolean?,
	[string]: any,
}

export type Integration = {
	id: Snowflake,
	name: string?,
	type: string?,
	enabled: boolean?,
	account: { id: string, name: string }?,
	[string]: any,
}

export type AuditLogChange = {
	key: string,
	new_value: any?,
	old_value: any?,
	[string]: any,
}

export type AuditLogEntry = {
	id: Snowflake,
	target_id: Snowflake?,
	user_id: Snowflake?,
	action_type: number,
	reason: string?,
	changes: { AuditLogChange }?,
	--- Shape depends on `action_type`; Discord documents it per action.
	options: { [string]: any }?,
	[string]: any,
}

--[[
	An audit-log page.

	The entries reference actors and targets by id only, so Discord ships the
	objects they point at alongside them -- resolving a `user_id` means
	looking it up in `users` here, not making a second request.
]]
export type AuditLog = {
	audit_log_entries: { AuditLogEntry },
	users: { User },
	webhooks: { Webhook },
	integrations: { Integration },
	threads: { Channel },
	application_commands: { ApplicationCommand },
	auto_moderation_rules: { AutoModRule },
	guild_scheduled_events: { ScheduledEvent },
	[string]: any,
}

export type ScheduledEvent = {
	id: Snowflake,
	guild_id: Snowflake,
	channel_id: Snowflake?,
	creator_id: Snowflake?,
	name: string,
	description: string?,
	scheduled_start_time: string,
	scheduled_end_time: string?,
	privacy_level: number,
	status: number,
	entity_type: number,
	entity_id: Snowflake?,
	entity_metadata: { location: string? }?,
	creator: User?,
	user_count: number?,
	image: string?,
	[string]: any,
}

export type AutoModAction = {
	type: number,
	--- `channel_id`, `duration_seconds` or `custom_message`, by action type.
	metadata: { [string]: any }?,
	[string]: any,
}

export type AutoModRule = {
	id: Snowflake,
	guild_id: Snowflake,
	name: string,
	creator_id: Snowflake,
	event_type: number,
	trigger_type: number,
	--- `keyword_filter`, `presets`, `mention_total_limit`, by trigger type.
	trigger_metadata: { [string]: any }?,
	actions: { AutoModAction },
	enabled: boolean,
	exempt_roles: { Snowflake }?,
	exempt_channels: { Snowflake }?,
	[string]: any,
}

export type ApplicationCommandChoice = {
	name: string,
	value: string | number,
	name_localizations: { [string]: string }?,
}

export type ApplicationCommandOption = {
	type: number,
	name: string,
	description: string,
	required: boolean?,
	choices: { ApplicationCommandChoice }?,
	--- Subcommands and groups nest their own options here.
	options: { ApplicationCommandOption }?,
	channel_types: { number }?,
	min_value: number?,
	max_value: number?,
	min_length: number?,
	max_length: number?,
	autocomplete: boolean?,
	name_localizations: { [string]: string }?,
	description_localizations: { [string]: string }?,
	[string]: any,
}

--[[
	A command as Discord stores it -- and, minus the server-assigned fields,
	exactly what a deploy sends. `@discord/commands` builds these.

	`id`, `application_id` and `version` are optional because they are absent
	on the way up and present on the way down.
]]
export type ApplicationCommand = {
	id: Snowflake?,
	type: number?,
	application_id: Snowflake?,
	guild_id: Snowflake?,
	name: string,
	--- Mandatory on chat-input commands, forbidden on context-menu ones.
	description: string?,
	options: { ApplicationCommandOption }?,
	default_member_permissions: string?,
	nsfw: boolean?,
	contexts: { number }?,
	integration_types: { number }?,
	version: Snowflake?,
	name_localizations: { [string]: string }?,
	description_localizations: { [string]: string }?,
	[string]: any,
}

export type Application = {
	id: Snowflake,
	name: string,
	icon: string?,
	description: string?,
	bot_public: boolean?,
	bot_require_code_grant: boolean?,
	owner: User?,
	flags: number?,
	[string]: any,
}

export type PruneResult = {
	--- Null on a prune run with `compute_prune_count` off.
	pruned: number?,
	[string]: any,
}

export type VanityUrl = {
	code: string?,
	uses: number?,
	[string]: any,
}

export type GuildWidget = {
	id: Snowflake,
	name: string,
	instant_invite: string?,
	channels: { Channel },
	members: { User },
	presence_count: number,
	[string]: any,
}

export type OnboardingPrompt = {
	id: Snowflake,
	type: number?,
	title: string?,
	options: { { [string]: any } }?,
	single_select: boolean?,
	required: boolean?,
	in_onboarding: boolean?,
	[string]: any,
}

export type GuildOnboarding = {
	guild_id: Snowflake,
	prompts: { OnboardingPrompt },
	default_channel_ids: { Snowflake },
	enabled: boolean,
	mode: number?,
	[string]: any,
}

export type Activity = {
	name: string,
	type: number,
	url: string?,
	state: string?,
	details: string?,
	[string]: any,
}

--- What UPDATE_PRESENCE takes, and what a PRESENCE_UPDATE dispatch carries.
export type Presence = {
	activities: { Activity },
	status: string,
	afk: boolean?,
	since: number?,
	user: User?,
	guild_id: Snowflake?,
	[string]: any,
}

export type VoiceState = {
	guild_id: Snowflake?,
	channel_id: Snowflake?,
	user_id: Snowflake,
	member: Member?,
	session_id: string,
	deaf: boolean,
	mute: boolean,
	self_deaf: boolean,
	self_mute: boolean,
	suppress: boolean,
	--- Stage channels only: when the user raised their hand.
	request_to_speak_timestamp: string?,
	[string]: any,
}

export type VoiceRegion = {
	id: string,
	name: string,
	optimal: boolean,
	deprecated: boolean,
	custom: boolean,
	[string]: any,
}

--- What a guild shows to someone outside it (discoverable guilds only).
export type GuildPreview = {
	id: Snowflake,
	name: string,
	icon: string?,
	splash: string?,
	discovery_splash: string?,
	emojis: { Emoji },
	stickers: { Sticker },
	features: { string },
	approximate_member_count: number,
	approximate_presence_count: number,
	description: string?,
	[string]: any,
}

export type GuildWidgetSettings = {
	enabled: boolean,
	channel_id: Snowflake?,
	[string]: any,
}

export type WelcomeScreenChannel = {
	channel_id: Snowflake,
	description: string,
	emoji_id: Snowflake?,
	emoji_name: string?,
	[string]: any,
}

export type WelcomeScreen = {
	description: string?,
	welcome_channels: { WelcomeScreenChannel },
	[string]: any,
}

--- A guild's raid-protection switches, as returned by the incident-actions route.
export type IncidentsData = {
	invites_disabled_until: string?,
	dms_disabled_until: string?,
	dm_spam_detected_at: string?,
	raid_detected_at: string?,
	[string]: any,
}

--- What a bulk ban reports: who was banned and who was not.
export type BulkBanResult = {
	banned_users: { Snowflake },
	failed_users: { Snowflake },
	[string]: any,
}

export type GuildTemplate = {
	code: string,
	name: string,
	description: string?,
	usage_count: number,
	creator_id: Snowflake,
	creator: User?,
	created_at: string,
	updated_at: string,
	source_guild_id: Snowflake,
	--- A partial guild snapshot; placeholder ids in it are integers, not snowflakes.
	serialized_source_guild: { [string]: any },
	is_dirty: boolean?,
	[string]: any,
}

export type ScheduledEventUser = {
	guild_scheduled_event_id: Snowflake,
	user: User,
	member: Member?,
	[string]: any,
}

export type StickerPack = {
	id: Snowflake,
	stickers: { Sticker },
	name: string,
	sku_id: Snowflake,
	cover_sticker_id: Snowflake?,
	description: string,
	banner_asset_id: Snowflake?,
	[string]: any,
}

export type SoundboardSound = {
	name: string,
	sound_id: Snowflake,
	volume: number,
	emoji_id: Snowflake?,
	emoji_name: string?,
	--- Absent on Discord's default sounds.
	guild_id: Snowflake?,
	available: boolean,
	user: User?,
	[string]: any,
}

export type StageInstance = {
	id: Snowflake,
	guild_id: Snowflake,
	channel_id: Snowflake,
	topic: string,
	privacy_level: number,
	guild_scheduled_event_id: Snowflake?,
	[string]: any,
}

--- One entry of the new paginated pin list: the message and when it was pinned.
export type MessagePin = {
	pinned_at: string,
	message: Message,
	[string]: any,
}

export type PinList = {
	items: { MessagePin },
	has_more: boolean,
	[string]: any,
}

--[[
	A guild message search result.

	When the guild has not been indexed yet Discord answers 202 with no
	results and `code = 110000` plus `retry_after` (seconds; 0 means "soon"),
	so check `code` before reading `messages`.
]]
export type GuildMessageSearch = {
	doing_deep_historical_index: boolean?,
	documents_indexed: number?,
	total_results: number?,
	--- Each hit is wrapped in its own array, a leftover from when Discord sent
	--- surrounding context. Read `hit[1]`.
	messages: { { Message } }?,
	threads: { Channel }?,
	members: { ThreadMember }?,
	code: number?,
	retry_after: number?,
	[string]: any,
}

export type InviteTargetUsersJob = {
	--- 0 unspecified, 1 processing, 2 completed, 3 failed.
	status: number,
	total_users: number,
	processed_users: number,
	created_at: string,
	completed_at: string?,
	error_message: string?,
	[string]: any,
}

export type ApplicationCommandPermission = {
	--- A role, user or channel id. The guild id means @everyone, and
	--- `guild_id - 1` means every channel.
	id: Snowflake,
	--- 1 role, 2 user, 3 channel.
	type: number,
	permission: boolean,
}

export type GuildApplicationCommandPermissions = {
	--- The command id, or the application id for the app-wide default.
	id: Snowflake,
	application_id: Snowflake,
	guild_id: Snowflake,
	permissions: { ApplicationCommandPermission },
	[string]: any,
}

export type RoleConnectionMetadata = {
	type: number,
	key: string,
	name: string,
	description: string,
	name_localizations: { [string]: string }?,
	description_localizations: { [string]: string }?,
	[string]: any,
}

export type ActivityInstance = {
	application_id: Snowflake,
	instance_id: string,
	launch_id: Snowflake,
	location: {
		id: string,
		--- "gc" (guild channel) or "pc" (DM / group DM).
		kind: string,
		channel_id: Snowflake,
		guild_id: Snowflake?,
		[string]: any,
	},
	users: { Snowflake },
	[string]: any,
}

export type Entitlement = {
	id: Snowflake,
	sku_id: Snowflake,
	application_id: Snowflake,
	user_id: Snowflake?,
	guild_id: Snowflake?,
	type: number,
	deleted: boolean,
	starts_at: string?,
	ends_at: string?,
	consumed: boolean?,
	[string]: any,
}

export type Sku = {
	id: Snowflake,
	type: number,
	application_id: Snowflake,
	name: string,
	slug: string,
	flags: number,
	[string]: any,
}

export type Subscription = {
	id: Snowflake,
	user_id: Snowflake,
	sku_ids: { Snowflake },
	entitlement_ids: { Snowflake },
	renewal_sku_ids: { Snowflake }?,
	current_period_start: string,
	current_period_end: string,
	status: number,
	canceled_at: string?,
	[string]: any,
}

----------------------------------------------------------------------------
-- Interactions
----------------------------------------------------------------------------

export type CommandOption = {
	name: string,
	type: number,
	value: OptionValue?,
	options: { CommandOption }?,
	focused: boolean?,
}

export type ResolvedData = {
	users: { [Snowflake]: User }?,
	members: { [Snowflake]: Member }?,
	roles: { [Snowflake]: Role }?,
	channels: { [Snowflake]: Channel }?,
	messages: { [Snowflake]: Message }?,
	attachments: { [Snowflake]: Attachment }?,
}

export type InteractionData = {
	id: Snowflake?,
	name: string?,
	type: number?,
	options: { CommandOption }?,
	resolved: ResolvedData?,
	custom_id: string?,
	component_type: number?,
	values: { string }?,
	--- Modal submissions only: labels and legacy rows, each wrapping one
	--- answered input. `Interaction.modalValues` flattens both shapes.
	components: { SubmittedComponent }?,
	target_id: Snowflake?,
	[string]: any,
}

export type Interaction = {
	id: Snowflake,
	application_id: Snowflake,
	type: number,
	data: InteractionData?,
	guild_id: Snowflake?,
	channel_id: Snowflake?,
	channel: Channel?,
	member: Member?,
	user: User?,
	token: string,
	version: number,
	message: Message?,
	app_permissions: string?,
	locale: string?,
	guild_locale: string?,
	[string]: any,
}

--- One entry in an autocomplete response.
export type AutocompleteChoice = {
	name: string,
	value: OptionValue,
	name_localizations: { [string]: string }?,
}

export type AutocompleteResponse = {
	choices: { AutocompleteChoice },
}

--- What an interaction callback returns when sent with `with_response`.
export type InteractionCallbackResponse = {
	interaction: {
		id: Snowflake,
		type: number,
		activity_instance_id: string?,
		response_message_id: Snowflake?,
		response_message_loading: boolean?,
		response_message_ephemeral: boolean?,
		[string]: any,
	},
	resource: {
		--- The callback type that was sent.
		type: number,
		--- CHANNEL_MESSAGE_WITH_SOURCE and UPDATE_MESSAGE only.
		message: Message?,
		--- LAUNCH_ACTIVITY only.
		activity_instance: { id: string }?,
		[string]: any,
	}?,
	[string]: any,
}

--[[
	The `data` half of an interaction callback.

	Which of the three it is depends on the callback type: a message body for
	a reply, a follow-up or an update, a modal for MODAL, and a choice list
	for an autocomplete answer. DEFERRED_* callbacks send no data at all.
]]
export type InteractionCallbackData = MessageBody | Modal | AutocompleteResponse

----------------------------------------------------------------------------
-- Bodies Discord accepts
----------------------------------------------------------------------------

--[[
	Which mentions in a message are allowed to actually ping.

	The two forms do not mix: Discord rejects a payload that both lists a
	category in `parse` and gives explicit ids from it. `@discord/payload`
	has a builder that keeps them apart.
]]
export type AllowedMentions = {
	--- Any of "users", "roles", "everyone".
	parse: { string }?,
	users: { Snowflake }?,
	roles: { Snowflake }?,
	--- Whether replying pings the person replied to.
	replied_user: boolean?,
}

--[[
	An attachment descriptor, as opposed to an upload.

	On an edit this is how attachments are KEPT: the ones listed survive and
	the ones left out are removed, so `attachments = {}` clears them all. On
	a create it names the files travelling in the multipart body, and `id` is
	their index.
]]
export type PartialAttachment = {
	id: Snowflake | number,
	filename: string?,
	description: string?,
	[string]: any,
}

--[[
	Everything you can put in a message, whether creating, editing, or
	answering an interaction.

	Three fields are this library's, not Discord's, and are translated by
	`@discord/payload` before the payload goes out: `ephemeral` and `silent`
	become flag bits, and `embed` is accepted as the singular of `embeds`.
	`allowedMentions` is accepted as an alias for `allowed_mentions` for the
	same reason -- see the note in `@discord/payload` about why the camelCase
	spelling must not be passed through untouched.
]]
export type MessagePayload = {
	content: string?,
	embeds: { Buildable<Embed> }?,
	--- Singular convenience; folded into `embeds`.
	embed: Buildable<Embed>?,
	--- Action rows, or any Components V2 layout. See `v2`.
	components: { Component }?,
	--- Sends as a Components V2 message: sets the IS_COMPONENTS_V2 flag,
	--- after which `content`, `embeds`, `poll` and stickers are refused.
	--- Implied when `components` holds a V2-only kind; `false` refuses
	--- V2 components outright. See `@discord/payload`.
	v2: boolean?,
	--- Uploads. Split out of the JSON body into multipart parts.
	files: { File }?,
	tts: boolean?,
	flags: number?,
	--- Only the caller sees the message. Becomes a flag bit.
	ephemeral: boolean?,
	--- Sends without a notification. Becomes a flag bit.
	silent: boolean?,
	allowed_mentions: AllowedMentions?,
	--- Alias for `allowed_mentions`.
	allowedMentions: AllowedMentions?,
	message_reference: MessageReference?,
	sticker_ids: { Snowflake }?,
	poll: Buildable<Poll>?,
	attachments: { PartialAttachment }?,
	[string]: any,
}

--- A payload, or a bare string as shorthand for `{ content = ... }`.
export type MessageInput = string | MessagePayload

--[[
	A message body as it goes on the wire.

	The same fields as `MessagePayload` minus this library's four
	conveniences, which `@discord/payload` has already resolved by the time a
	body has this type: `ephemeral` and `silent` are folded into `flags`,
	`embed` into `embeds`, and `allowedMentions` into `allowed_mentions`.
]]
export type MessageBody = {
	content: string?,
	embeds: { Embed }?,
	components: { Component }?,
	tts: boolean?,
	flags: number?,
	allowed_mentions: AllowedMentions?,
	message_reference: MessageReference?,
	sticker_ids: { Snowflake }?,
	poll: Poll?,
	attachments: { PartialAttachment }?,
	[string]: any,
}

export type ChannelPatch = {
	name: string?,
	type: number?,
	position: number?,
	topic: string?,
	nsfw: boolean?,
	rate_limit_per_user: number?,
	bitrate: number?,
	user_limit: number?,
	permission_overwrites: { Overwrite }?,
	parent_id: Snowflake?,
	--- Threads only.
	archived: boolean?,
	auto_archive_duration: number?,
	locked: boolean?,
	[string]: any,
}

export type ChannelCreate = {
	name: string,
	type: number?,
	topic: string?,
	bitrate: number?,
	user_limit: number?,
	rate_limit_per_user: number?,
	position: number?,
	permission_overwrites: { Overwrite }?,
	parent_id: Snowflake?,
	nsfw: boolean?,
	[string]: any,
}

export type ChannelPosition = {
	id: Snowflake,
	position: number?,
	lock_permissions: boolean?,
	parent_id: Snowflake?,
}

export type ThreadCreate = {
	name: string,
	auto_archive_duration: number?,
	--- Omit on a thread started from a message; it inherits.
	type: number?,
	invitable: boolean?,
	rate_limit_per_user: number?,
	[string]: any,
}

export type ForumThreadCreate = {
	name: string,
	auto_archive_duration: number?,
	rate_limit_per_user: number?,
	applied_tags: { Snowflake }?,
	[string]: any,
}

export type InviteCreate = {
	max_age: number?,
	max_uses: number?,
	temporary: boolean?,
	unique: boolean?,
	target_type: number?,
	target_user_id: Snowflake?,
	target_application_id: Snowflake?,
	--- Only these users can see and accept the invite (max 1000).
	target_user_ids: { Snowflake }?,
	--- Roles granted on accept. Needs MANAGE_ROLES.
	role_ids: { Snowflake }?,
	[string]: any,
}

export type GuildPatch = {
	name: string?,
	description: string?,
	--- A `data:` URI, not a URL. `Util.dataUri` builds one.
	icon: string?,
	banner: string?,
	splash: string?,
	owner_id: Snowflake?,
	afk_channel_id: Snowflake?,
	afk_timeout: number?,
	system_channel_id: Snowflake?,
	verification_level: number?,
	default_message_notifications: number?,
	explicit_content_filter: number?,
	preferred_locale: string?,
	features: { string }?,
	[string]: any,
}

export type MemberPatch = {
	nick: string?,
	roles: { Snowflake }?,
	mute: boolean?,
	deaf: boolean?,
	channel_id: Snowflake?,
	--- ISO timestamp to time the member out until; `Json.null` clears it.
	communication_disabled_until: string?,
	flags: number?,
	[string]: any,
}

export type RolePatch = {
	name: string?,
	permissions: string?,
	color: number?,
	hoist: boolean?,
	mentionable: boolean?,
	icon: string?,
	unicode_emoji: string?,
	[string]: any,
}

export type RolePosition = {
	id: Snowflake,
	position: number?,
}

export type PruneOptions = {
	days: number?,
	compute_prune_count: boolean?,
	include_roles: { Snowflake }?,
	[string]: any,
}

export type AuditLogQuery = {
	user_id: Snowflake?,
	action_type: number?,
	before: Snowflake?,
	after: Snowflake?,
	limit: number?,
}

export type ScheduledEventCreate = {
	name: string,
	scheduled_start_time: string,
	privacy_level: number?,
	entity_type: number?,
	channel_id: Snowflake?,
	description: string?,
	scheduled_end_time: string?,
	entity_metadata: { location: string? }?,
	image: string?,
	[string]: any,
}

export type ScheduledEventPatch = {
	name: string?,
	scheduled_start_time: string?,
	scheduled_end_time: string?,
	privacy_level: number?,
	entity_type: number?,
	channel_id: Snowflake?,
	description: string?,
	entity_metadata: { location: string? }?,
	status: number?,
	image: string?,
	[string]: any,
}

export type AutoModRuleCreate = {
	name: string,
	event_type: number,
	trigger_type: number,
	trigger_metadata: { [string]: any }?,
	actions: { AutoModAction },
	enabled: boolean?,
	exempt_roles: { Snowflake }?,
	exempt_channels: { Snowflake }?,
	[string]: any,
}

export type AutoModRulePatch = {
	name: string?,
	event_type: number?,
	trigger_metadata: { [string]: any }?,
	actions: { AutoModAction }?,
	enabled: boolean?,
	exempt_roles: { Snowflake }?,
	exempt_channels: { Snowflake }?,
	[string]: any,
}

export type ApplicationPatch = {
	description: string?,
	icon: string?,
	cover_image: string?,
	interactions_endpoint_url: string?,
	tags: { string }?,
	flags: number?,
	[string]: any,
}

export type WebhookCreate = {
	name: string,
	--- A `data:` URI.
	avatar: string?,
}

export type WebhookPatch = {
	name: string?,
	--- A `data:` URI, or `Json.null` to clear.
	avatar: string?,
	--- Moves the webhook. Rejected on the token-authenticated route.
	channel_id: Snowflake?,
	[string]: any,
}

--- A permission overwrite as `editPermissions` sends it. `type` is
--- `Const.OverwriteType`: 0 role, 1 member. Omitted bits default to "0".
export type OverwritePatch = {
	allow: string?,
	deny: string?,
	type: number,
}

--- Adding a user who authorised the app with the `guilds.join` scope.
export type MemberAdd = {
	--- The USER's OAuth2 access token, not the bot token.
	access_token: string,
	nick: string?,
	roles: { Snowflake }?,
	mute: boolean?,
	deaf: boolean?,
	[string]: any,
}

export type GuildWidgetPatch = {
	enabled: boolean?,
	channel_id: Snowflake?,
	[string]: any,
}

export type WelcomeScreenPatch = {
	enabled: boolean?,
	welcome_channels: { WelcomeScreenChannel }?,
	description: string?,
	[string]: any,
}

export type OnboardingPatch = {
	prompts: { OnboardingPrompt }?,
	default_channel_ids: { Snowflake }?,
	enabled: boolean?,
	mode: number?,
	[string]: any,
}

--- ISO timestamps at most 24 hours ahead; `Json.null` lifts the action.
export type IncidentActionsPatch = {
	invites_disabled_until: string?,
	dms_disabled_until: string?,
	[string]: any,
}

export type EmojiPatch = {
	name: string?,
	--- `Json.null` makes the emoji usable by everyone again.
	roles: { Snowflake }?,
	[string]: any,
}

export type StickerCreate = {
	--- 2-30 characters.
	name: string,
	--- Empty, or 2-100 characters.
	description: string?,
	--- Autocomplete tags, max 200 characters. Required.
	tags: string,
	--- PNG, APNG, GIF or Lottie JSON, max 512 KiB and 320x320.
	file: File,
}

export type StickerPatch = {
	name: string?,
	description: string?,
	tags: string?,
	[string]: any,
}

export type GuildTemplateCreate = {
	name: string,
	description: string?,
	[string]: any,
}

export type GuildTemplatePatch = {
	name: string?,
	description: string?,
	[string]: any,
}

export type SoundboardSoundCreate = {
	name: string,
	--- A `data:` URI of MP3 or OGG audio, max 512 KB and 5.2 seconds.
	sound: string,
	volume: number?,
	emoji_id: Snowflake?,
	emoji_name: string?,
	[string]: any,
}

export type SoundboardSoundPatch = {
	name: string?,
	volume: number?,
	emoji_id: Snowflake?,
	emoji_name: string?,
	[string]: any,
}

export type StageInstanceCreate = {
	channel_id: Snowflake,
	topic: string,
	privacy_level: number?,
	--- Pings @everyone; needs MENTION_EVERYONE.
	send_start_notification: boolean?,
	guild_scheduled_event_id: Snowflake?,
	[string]: any,
}

export type StageInstancePatch = {
	topic: string?,
	privacy_level: number?,
	[string]: any,
}

export type CurrentVoiceStatePatch = {
	channel_id: Snowflake?,
	suppress: boolean?,
	request_to_speak_timestamp: string?,
	[string]: any,
}

export type VoiceStatePatch = {
	channel_id: Snowflake?,
	suppress: boolean?,
	[string]: any,
}

--- Every field of a command is optional on an edit, and a field that is
--- sent replaces the stored one whole.
export type ApplicationCommandPatch = {
	name: string?,
	description: string?,
	options: { ApplicationCommandOption }?,
	default_member_permissions: string?,
	nsfw: boolean?,
	contexts: { number }?,
	integration_types: { number }?,
	name_localizations: { [string]: string }?,
	description_localizations: { [string]: string }?,
	[string]: any,
}

export type EntitlementQuery = {
	user_id: Snowflake?,
	--- Joined with commas on the wire, which is how this route reads a list.
	sku_ids: { Snowflake }?,
	guild_id: Snowflake?,
	before: Snowflake?,
	after: Snowflake?,
	limit: number?,
	exclude_ended: boolean?,
	exclude_deleted: boolean?,
}

export type TestEntitlementCreate = {
	sku_id: Snowflake,
	owner_id: Snowflake,
	--- 1 guild, 2 user. `Const.EntitlementOwnerType`.
	owner_type: number,
}

export type ThreadMembersQuery = {
	--- Also turns on pagination.
	with_member: boolean?,
	after: Snowflake?,
	limit: number?,
}

export type ArchivedThreadsQuery = {
	--- An ISO timestamp for the public and private lists; a thread id for
	--- the joined-private list.
	before: string?,
	limit: number?,
}

export type ScheduledEventUsersQuery = {
	limit: number?,
	with_member: boolean?,
	before: Snowflake?,
	after: Snowflake?,
}

--- Filters for `guilds.searchMessages`. The array fields go out as the
--- key repeated once per element.
export type GuildMessageSearchQuery = {
	content: string?,
	limit: number?,
	offset: number?,
	max_id: Snowflake?,
	min_id: Snowflake?,
	slop: number?,
	channel_id: { Snowflake }?,
	--- "user", "bot", "webhook"; prefix with "-" to exclude.
	author_type: { string }?,
	author_id: { Snowflake }?,
	mentions: { Snowflake }?,
	mentions_role_id: { Snowflake }?,
	mention_everyone: boolean?,
	replied_to_user_id: { Snowflake }?,
	replied_to_message_id: { Snowflake }?,
	pinned: boolean?,
	--- "image", "sound", "video", "file", "sticker", "embed", "link",
	--- "poll", "snapshot"; prefix with "-" to exclude.
	has: { string }?,
	embed_type: { string }?,
	embed_provider: { string }?,
	link_hostname: { string }?,
	attachment_filename: { string }?,
	attachment_extension: { string }?,
	--- "timestamp" (default) or "relevance".
	sort_by: string?,
	--- "asc" or "desc". Ignored when sorting by relevance.
	sort_order: string?,
	include_nsfw: boolean?,
}


----------------------------------------------------------------------------
-- Gateway
----------------------------------------------------------------------------

export type Ready = {
	v: number,
	user: User,
	guilds: { { id: Snowflake, unavailable: boolean? } },
	session_id: string,
	resume_gateway_url: string,
	application: { id: Snowflake, flags: number },
	[string]: any,
}

--- What GUILD_MEMBERS_CHUNK / REQUEST_GUILD_MEMBERS takes.
export type MemberRequest = {
	query: string?,
	limit: number?,
	presences: boolean?,
	user_ids: { Snowflake }?,
	nonce: string?,
	[string]: any,
}

--[[
	Dispatch payloads: what `client:on(name, fn)` hands `fn`.

	Events that carry a whole object reuse its type -- `messageCreate` and
	`messageUpdate` are a `Message`, `channelCreate` a `Channel`, `guildCreate`
	a `Guild`. The ones below are the events whose payload is its own shape.
	`docs/events.md` lists every event against its type, and
	`@discord/events` is the same table in code, which `client:on` is typed by.
]]

--- `guildMemberAdd`, `guildMemberUpdate`: a member plus the guild it is in.
export type GuildMemberEvent = {
	guild_id: Snowflake,
	user: User,
	roles: { Snowflake },
	nick: string?,
	avatar: string?,
	joined_at: string?,
	premium_since: string?,
	pending: boolean?,
	communication_disabled_until: string?,
	flags: number?,
	[string]: any,
}

--- `guildMemberRemove`. Only the user survives the member.
export type GuildMemberRemove = { guild_id: Snowflake, user: User, [string]: any }

--- `guildBanAdd`, `guildBanRemove`.
export type GuildBanEvent = { guild_id: Snowflake, user: User, [string]: any }

--- `guildRoleCreate`, `guildRoleUpdate`.
export type GuildRoleEvent = { guild_id: Snowflake, role: Role, [string]: any }

export type GuildRoleDelete = { guild_id: Snowflake, role_id: Snowflake, [string]: any }

export type GuildEmojisUpdate = { guild_id: Snowflake, emojis: { Emoji }, [string]: any }

export type GuildStickersUpdate = { guild_id: Snowflake, stickers: { Sticker }, [string]: any }

--[[
	`guildDelete`. When `unavailable` is true the guild is in an outage, not
	gone -- the bot is still a member and the cache keeps it. Only a delete
	without `unavailable` means the bot was removed.
]]
export type UnavailableGuild = { id: Snowflake, unavailable: boolean?, [string]: any }

--- `guildMembersChunk`, the reply to a member request (op 8).
export type GuildMembersChunk = {
	guild_id: Snowflake,
	members: { Member },
	chunk_index: number,
	chunk_count: number,
	not_found: { Snowflake }?,
	presences: { PresenceUpdate }?,
	nonce: string?,
	[string]: any,
}

--- `guildAuditLogEntryCreate`. Needs the `guildModeration` intent and the
--- VIEW_AUDIT_LOG permission.
export type GuildAuditLogEntryCreate = AuditLogEntry & { guild_id: Snowflake }

--- `guildScheduledEventUserAdd`, `guildScheduledEventUserRemove`.
export type GuildScheduledEventUserEvent = {
	guild_scheduled_event_id: Snowflake,
	user_id: Snowflake,
	guild_id: Snowflake,
	[string]: any,
}

export type MessageDelete = { id: Snowflake, channel_id: Snowflake, guild_id: Snowflake?, [string]: any }

export type MessageDeleteBulk = {
	ids: { Snowflake },
	channel_id: Snowflake,
	guild_id: Snowflake?,
	[string]: any,
}

--[[
	`messageReactionAdd`. Arrives for any message, including ones this
	process has never seen, which is why reaction roles are built on it
	rather than on a cache. `member` is present in guilds only.
]]
export type MessageReactionAdd = {
	user_id: Snowflake,
	channel_id: Snowflake,
	message_id: Snowflake,
	guild_id: Snowflake?,
	member: Member?,
	emoji: Emoji,
	message_author_id: Snowflake?,
	burst: boolean,
	burst_colors: { string }?,
	type: number,
	[string]: any,
}

export type MessageReactionRemove = {
	user_id: Snowflake,
	channel_id: Snowflake,
	message_id: Snowflake,
	guild_id: Snowflake?,
	emoji: Emoji,
	burst: boolean,
	type: number,
	[string]: any,
}

--- `messageReactionRemoveAll`.
export type MessageReactionRemoveAll = {
	channel_id: Snowflake,
	message_id: Snowflake,
	guild_id: Snowflake?,
	[string]: any,
}

--- `messageReactionRemoveEmoji`.
export type MessageReactionRemoveEmoji = {
	channel_id: Snowflake,
	message_id: Snowflake,
	guild_id: Snowflake?,
	emoji: Emoji,
	[string]: any,
}

--- `messagePollVoteAdd`, `messagePollVoteRemove`.
export type MessagePollVoteEvent = {
	user_id: Snowflake,
	channel_id: Snowflake,
	message_id: Snowflake,
	guild_id: Snowflake?,
	answer_id: number,
	[string]: any,
}

export type ChannelPinsUpdate = {
	channel_id: Snowflake,
	guild_id: Snowflake?,
	last_pin_timestamp: string?,
	[string]: any,
}

export type TypingStart = {
	channel_id: Snowflake,
	guild_id: Snowflake?,
	user_id: Snowflake,
	--- Unix seconds.
	timestamp: number,
	member: Member?,
	[string]: any,
}

export type InviteCreateEvent = {
	channel_id: Snowflake,
	code: string,
	created_at: string,
	guild_id: Snowflake?,
	inviter: User?,
	max_age: number,
	max_uses: number,
	temporary: boolean,
	uses: number,
	[string]: any,
}

export type InviteDeleteEvent = { channel_id: Snowflake, guild_id: Snowflake?, code: string, [string]: any }

--- `presenceUpdate`. Needs the `guildPresences` privileged intent.
export type PresenceUpdate = {
	user: { id: Snowflake, [string]: any },
	guild_id: Snowflake,
	status: string,
	activities: { Activity },
	client_status: { desktop: string?, mobile: string?, web: string? },
	[string]: any,
}

--- `threadListSync`: sent when the bot gains access to a channel's threads.
export type ThreadListSync = {
	guild_id: Snowflake,
	channel_ids: { Snowflake }?,
	threads: { Channel },
	members: { ThreadMember },
	[string]: any,
}

export type ThreadMembersUpdate = {
	id: Snowflake,
	guild_id: Snowflake,
	member_count: number,
	added_members: { ThreadMember }?,
	removed_member_ids: { Snowflake }?,
	[string]: any,
}

--- `autoModerationActionExecution`. `content` is empty without the
--- `messageContent` privileged intent.
export type AutoModerationActionExecution = {
	guild_id: Snowflake,
	action: AutoModAction,
	rule_id: Snowflake,
	rule_trigger_type: number,
	user_id: Snowflake,
	channel_id: Snowflake?,
	message_id: Snowflake?,
	alert_system_message_id: Snowflake?,
	content: string,
	matched_keyword: string?,
	matched_content: string?,
	[string]: any,
}

export type WebhooksUpdate = { guild_id: Snowflake, channel_id: Snowflake, [string]: any }

--- `guildIntegrationsUpdate`, and the shape `integrationDelete` extends.
export type GuildIdEvent = { guild_id: Snowflake, [string]: any }

--- `voiceServerUpdate`. Useless without a voice client, which Lute cannot
--- host; typed so a bot that forwards it to one can.
export type VoiceServerUpdate = { token: string, guild_id: Snowflake, endpoint: string?, [string]: any }

--- `threadMemberUpdate`: the bot's own membership of a thread changed.
export type ThreadMemberUpdate = ThreadMember & { guild_id: Snowflake }

--- `integrationCreate`, `integrationUpdate`.
export type IntegrationEvent = Integration & { guild_id: Snowflake }

export type IntegrationDelete = {
	id: Snowflake,
	guild_id: Snowflake,
	--- The bot or OAuth2 application of a removed app integration.
	application_id: Snowflake?,
	[string]: any,
}

export type GuildSoundboardSoundDelete = { sound_id: Snowflake, guild_id: Snowflake, [string]: any }

--- `guildSoundboardSoundsUpdate`, and `soundboardSounds` (the reply to a
--- soundboard request, op 31).
export type GuildSoundboardSounds = { guild_id: Snowflake, soundboard_sounds: { SoundboardSound }, [string]: any }

--- `voiceChannelEffectSend`: someone sent an emoji reaction or soundboard
--- sound in a voice channel the bot can see.
export type VoiceChannelEffectSend = {
	channel_id: Snowflake,
	guild_id: Snowflake,
	user_id: Snowflake,
	emoji: Emoji?,
	animation_type: number?,
	animation_id: number?,
	sound_id: (Snowflake | number)?,
	sound_volume: number?,
	[string]: any,
}

export type VoiceChannelStatusUpdate = { id: Snowflake, guild_id: Snowflake, status: string?, [string]: any }

export type VoiceChannelStartTimeUpdate = {
	id: Snowflake,
	guild_id: Snowflake,
	--- ISO timestamp, or nil when the call ended.
	voice_start_time: string?,
	[string]: any,
}

--- `rateLimited`: a gateway request (op 8, a member fetch) was refused for
--- going too fast. `retry_after` is in seconds.
export type RateLimited = { opcode: number, retry_after: number, meta: { [string]: any }, [string]: any }

return {}
