# Permissions

Discord never tells you what a member may actually do in a channel. It gives
you role bitmasks and a list of channel overwrites, and leaves the rest to
you. `Discord.Permissions` does that arithmetic, `Discord.Bitfield` holds the
values, and this page explains both, plus the role hierarchy that decides
whom your bot may act on.

## Why permissions are never numbers

Discord sends a permission set as a **decimal string**, like
`"2251799813685248"`. Each permission is one bit, and the highest in use is
bit 52 and rising. Luau has no 64-bit integer: `bit32` stops at 32 bits, and a
double stops representing consecutive integers exactly above 2^53. So
`tonumber(role.permissions)` works today for most roles and breaks without an
error once a high bit is set.

`Bitfield` stores the set as two 32-bit halves (`hi` and `lo`), each always
an exact integer, and converts to and from decimal with long division rather
than going through a float. Treat permission values as opaque `Bitfield`s,
and turn them back into strings only to send them.

## `Permissions`

```luau
local Permissions = Discord.Permissions

local wanted = Permissions.of("kickMembers", "banMembers")
local held = Permissions.parse(role.permissions)

Permissions.has(held, "banMembers")        -- by name
Permissions.has(held, wanted)              -- every bit in `wanted`
Permissions.list(held)                     -- { "addReactions", "banMembers", ... }, sorted
wanted:toString()                          -- "6", for the wire
```

| Function | Does |
| --- | --- |
| `Permissions.of(...names)` | Combines permission names into one field. An unknown name throws: a typo that silently meant "no permission" would let everyone through. |
| `Permissions.parse(text?)` | Parses Discord's decimal string. `nil` or `""` gives an empty field. |
| `Permissions.list(field)` | The names set in a field, sorted. |
| `Permissions.has(field, nameOrField)` | True if every bit is set, **or if the field holds `administrator`**. |
| `Permissions.forMember(guild, member, roles?)` | Guild-wide permissions. See below. |
| `Permissions.forChannel(guild, member, channel, roles?)` | Effective permissions in one channel. |
| `Permissions.outranks(guild, actor, target, roles?)` | Role hierarchy. |
| `Permissions.isTimedOut(member)` | True while the member's timeout is in the future. |
| `Permissions.Flags` | Every permission by name, as a single-bit `Bitfield`. |
| `Permissions.NONE`, `Permissions.ALL` | The empty field, and every known permission. |

`roles` is an optional map of role id to role. With the client's cache,
`client.cache:getRoles(guildId)` is exactly that. Without it, the functions
build one from `guild.roles`.

Use `Permissions.has` rather than the bitfield's own `has` for checks. The
bitfield method doesn't know about `administrator`, and it reads a string
argument as a decimal number, not a name: `field:has("banMembers")` throws.

## `Bitfield`

Values are immutable: every operation returns a new field.

| Function | Does |
| --- | --- |
| `Bitfield.fromString(text)` | From a decimal string. The form Discord sends. |
| `Bitfield.fromBit(n)` | A single bit, 0 to 63. |
| `Bitfield.fromNumber(n)` | From a number below 2^53. |
| `Bitfield.of(...)` | Combines any mix of fields, decimal strings and numbers. |
| `Bitfield.empty` | No bits. |
| `field:has(other)`, `field:hasAny(other)` | All bits of `other` set, or at least one. |
| `field:union(other)`, `field:without(other)`, `field:intersect(other)` | Set operations. |
| `field:isEmpty()`, `field:bits()` | Emptiness, and the set bit positions ascending. |
| `field:toString()`, `tostring(field)` | Decimal string, for the wire. |
| `field:toNumber()` | Exact only below 2^53. For display, never for the wire. |

`==` compares two fields by value.

## Guild permissions: `forMember`

A member's guild-wide permissions are the `@everyone` role's permissions
plus those of every role they hold. The `@everyone` role always has the same
id as the guild. The server owner, and anyone whose roles include
`administrator`, gets `Permissions.ALL`.

The owner check reads `member.user.id`. Some member objects arrive without a
`user` field (the resolved members in an interaction's options are one
example), so set it before passing one in if the member could be the owner.

## Channel permissions: `forChannel`

Channel overwrites adjust the guild permissions per channel, and the order
they're applied in decides the answer. `forChannel` applies them exactly as
Discord does:

1. Start from `forMember`. The owner or an administrator gets everything and
   stops here: overwrites can't restrict them.
2. Apply the `@everyone` overwrite (the one whose id is the guild id): remove
   its denied bits, then add its allowed bits.
3. Take **every** role overwrite for roles the member holds. Remove the union
   of all their denies, then add the union of all their allows.
4. Apply the member's own overwrite, if there is one: deny, then allow.
5. If the result lacks `viewChannel`, return nothing. A member who can't see
   a channel has no permissions in it, whatever else is set.
6. If the member is timed out, keep only `viewChannel` and
   `readMessageHistory`.

Step 3 is the one hand-written versions get wrong. Denies and allows are
applied in two passes across all roles, not role by role, so one role's
allow always beats another role's deny, whatever the role order. A per-role
loop gives an answer that depends on which role came first.

```luau
local function canPost(client: Discord.Client, guildId: string, channelId: string, member: Discord.Member): boolean
	local guild = client.cache:getGuild(guildId)
	local channel = client.cache:getChannel(channelId)
	if guild == nil or channel == nil then
		return false
	end
	local perms = Permissions.forChannel(guild, member, channel, client.cache:getRoles(guildId))
	return Permissions.has(perms, Permissions.of("viewChannel", "sendMessages"))
end
```

Threads don't have overwrites of their own. They inherit the parent's, so
pass the parent channel (`thread.parent_id`) and check
`sendMessagesInThreads` rather than `sendMessages`.

## Role hierarchy: `outranks`

Permissions say *what* someone may do. The hierarchy says *to whom*. Discord
refuses to let anyone, a bot included, kick, ban, time out, rename or edit
the roles of a member whose highest role is at or above their own. The owner
outranks everyone and can't be acted on at all.

`Permissions.outranks(guild, actor, target, roles?)` returns true when
`actor`'s highest role is strictly above `target`'s, or `actor` is the owner.
It returns false when `target` is the owner. Checking this before acting turns
Discord's bare 403 into a sentence the user can do something about.

Assigning a role follows the same rule, with the role itself as the target:
the bot's highest role must be above the role it's giving out. Compare
`role.position` directly for that.

## Timeouts: `isTimedOut`

A timed-out member keeps only `viewChannel` and `readMessageHistory` in
every channel, which `forChannel` already applies.
`Permissions.isTimedOut(member)` reads `communication_disabled_until` and
compares it to the current time. The field can still be set after the
timeout has expired, so check the time rather than whether the field is
present.

## Inside a handler: `ix:appPermissions()` and `ix:memberPermissions()`

Every interaction carries two permission sets Discord has already computed
for the channel it came from:

- `ix:appPermissions()` is what the **bot** may do there.
- `ix:memberPermissions()` is what the **user who invoked it** may do there.
  It's empty in DMs, where there's no member.

Both are `Bitfield`s, both are free (they ride along on the payload), and
both are more reliable than recomputing, because Discord's computation
includes things the cache may not know. Prefer them whenever the question is
about the interaction's own channel.

```luau
if not Permissions.has(ix:appPermissions(), "embedLinks") then
	ix:reply("I can't post embeds here. Give me Embed Links.")
	return
end
```

## Hiding commands: `defaultPermissions`

A command can declare the permissions a member needs to see it:

```luau
Commands.slash("purge", "Delete recent messages")
	:integerOption("count", "How many", { required = true, min = 2, max = 100 })
	:defaultPermissions("manageMessages")
	:guildOnly()
```

This is a default, not a lock. Server admins can override it per role and
per channel in **Server Settings > Integrations**, so a command that must not
run without a permission still has to check at invoke time. Calling
`defaultPermissions()` with no names sets it to `"0"`, which hides the
command from everyone except administrators. See [commands.md](commands.md).

## Worked example: can the bot act on this member?

A `/ban` command has three separate questions to answer, and Discord only
enforces the last two:

1. **May the invoker ban this person?** The bot acts on its own authority,
   so Discord doesn't check the invoker at all. Without this check, anyone
   with Ban Members could use the bot to ban someone above them.
2. **Does the bot hold Ban Members?**
3. **Does the bot outrank the target?**

```luau
--- Why the bot can't ban `targetId`, or nil when it can.
local function whyCannotBan(client: Discord.Client, guildId: string, targetId: string): string?
	local cache = client.cache
	local guild = cache:getGuild(guildId)
	local me = client.user
	if guild == nil or me == nil then
		return "I do not know that server yet"
	end
	local roles = cache:getRoles(guildId)

	-- The cache usually has the bot's own member. The target may need a fetch.
	local myself = cache:getMember(guildId, me.id) or client.api.guilds.getMember(guildId, me.id)
	local target = cache:getMember(guildId, targetId) or client.api.guilds.getMember(guildId, targetId)

	if not Permissions.has(Permissions.forMember(guild, myself, roles), "banMembers") then
		return "I need the Ban Members permission"
	end
	if not Permissions.outranks(guild, myself, target, roles) then
		return "their highest role is at or above mine"
	end
	return nil
end

client:command("ban", function(ix: Discord.Interaction)
	local guildId = ix:requireGuildId()
	local target = ix:requireUser("user")

	-- 1. The invoker. Their permissions come precomputed on the interaction.
	if not Permissions.has(ix:memberPermissions(), "banMembers") then
		ix:replyEphemeral("You need Ban Members to use this.")
		return
	end
	local actor = ix.member
	local targetMember = ix:getMember("user") -- nil if they aren't in the server
	local guild = client.cache:getGuild(guildId)
	if actor ~= nil and targetMember ~= nil and guild ~= nil then
		targetMember.user = target -- resolved members come without `user`
		if not Permissions.outranks(guild, actor, targetMember, client.cache:getRoles(guildId)) then
			ix:replyEphemeral("You can only ban members below your highest role.")
			return
		end
	end

	-- 2 and 3. The bot.
	local problem = whyCannotBan(client, guildId, target.id)
	if problem ~= nil then
		ix:replyEphemeral(`I can't ban {target.username}: {problem}.`)
		return
	end

	client.api.guilds.banMember(guildId, target.id, nil, `/ban by {ix.user.username}`)
	ix:reply(`Banned {target.username}.`)
end)
```

`guilds.getMember` throws a 404 `ApiError` if the target isn't in the
server. Discord lets you ban someone who isn't a member, so a real command
would catch that with `ApiError.isUnknownResource` and skip the hierarchy
check. The bot's guild-wide permissions are the right question here because
bans aren't per channel. For something channel-scoped, like deleting
messages, use `forChannel` or `ix:appPermissions()`.

## Permission names

These are the names `Permissions.of` accepts, with their bit positions. The
source of truth is `Const.PermissionBits` in `src/const.luau`.

| Name | Bit | Name | Bit |
| --- | --- | --- | --- |
| `createInstantInvite` | 0 | `manageWebhooks` | 29 |
| `kickMembers` | 1 | `manageGuildExpressions` | 30 |
| `banMembers` | 2 | `useApplicationCommands` | 31 |
| `administrator` | 3 | `requestToSpeak` | 32 |
| `manageChannels` | 4 | `manageEvents` | 33 |
| `manageGuild` | 5 | `manageThreads` | 34 |
| `addReactions` | 6 | `createPublicThreads` | 35 |
| `viewAuditLog` | 7 | `createPrivateThreads` | 36 |
| `prioritySpeaker` | 8 | `useExternalStickers` | 37 |
| `stream` | 9 | `sendMessagesInThreads` | 38 |
| `viewChannel` | 10 | `useEmbeddedActivities` | 39 |
| `sendMessages` | 11 | `moderateMembers` | 40 |
| `sendTtsMessages` | 12 | `viewCreatorMonetizationAnalytics` | 41 |
| `manageMessages` | 13 | `useSoundboard` | 42 |
| `embedLinks` | 14 | `createGuildExpressions` | 43 |
| `attachFiles` | 15 | `createEvents` | 44 |
| `readMessageHistory` | 16 | `useExternalSounds` | 45 |
| `mentionEveryone` | 17 | `sendVoiceMessages` | 46 |
| `useExternalEmojis` | 18 | `setVoiceChannelStatus` | 48 |
| `viewGuildInsights` | 19 | `sendPolls` | 49 |
| `connect` | 20 | `useExternalApps` | 50 |
| `speak` | 21 | `pinMessages` | 51 |
| `muteMembers` | 22 | `bypassSlowmode` | 52 |
| `deafenMembers` | 23 | | |
| `moveMembers` | 24 | | |
| `useVad` | 25 | | |
| `changeNickname` | 26 | | |
| `manageNicknames` | 27 | | |
| `manageRoles` | 28 | | |

Discord sometimes splits a permission out of an existing one. Since
2026-02-23, pinning needs `pinMessages`, and `manageMessages` alone is no
longer enough. A bot whose own check still says `manageMessages` will
disagree with Discord. See [troubleshooting.md](troubleshooting.md).

To send permissions, for a role or an overwrite, convert with `toString()`:

```luau
client.api.guilds.createRole(guildId, {
	name = "Helpers",
	permissions = Permissions.of("manageMessages", "moderateMembers"):toString(),
})
client.api.channels.editPermissions(channelId, roleId, {
	type = Discord.Const.OverwriteType.ROLE,
	deny = Permissions.of("sendMessages"):toString(),
})
```
