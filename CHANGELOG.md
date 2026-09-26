# Changelog

All notable changes to this project. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/), and while the version is 0.x a
minor release may change the API.

## [0.3.0] - Unreleased

The first public release.

### Added

- **REST coverage.** About 120 new routes, bringing the total to about 200.
  - New namespaces: `stickers`, `soundboard`, `stageInstances`, `voice` and
    `monetization` (SKUs, entitlements, subscriptions).
  - Webhook management and webhook messages.
  - Getting and editing single commands, command permissions (read-only), and
    application emoji.
  - Archived threads and thread members.
  - Guild preview, welcome screen, widget, onboarding edits, templates,
    integrations, bulk ban, role member counts, incident actions and message
    search.
  - Invite target users.
  - `interactions.createResponseWithResult` for `with_response`.
- **`Api.cdn`.** URL builders for avatars (including the default avatar,
  computed without float precision loss), banners, guild and role icons,
  emoji and stickers.
- **Components V2.** `Components.text`, `section`, `thumbnail`, `gallery`,
  `file`, `separator` and `container`.
  - Set `v2 = true`, or use a V2 component and the flag is set for you.
  - A V2 message may not carry content, embeds, polls or stickers, and has a
    budget of 40 components. Both rules are enforced.
- **Modal components.** `Components.label`, `fileUpload`, `radioGroup`,
  `checkboxGroup` and `checkbox`, plus selects and text displays inside
  modals.
  - Read the results with `ix:modalValue`, `modalSelected`, `modalChecked`,
    `modalFiles`, `modalUsers`, `modalRoles` and `modalChannels`.
- **Premium buttons, and select defaults.** `sku` buttons, plus `required`
  and `defaults` on selects.
- **Command builder additions.** `numberOption`, `mentionableOption`,
  `userInstallable()`, and option name and description localizations.
- **Narrowing helpers.** For required options: `ix:requireUser`,
  `requireMember`, `requireRole`, `requireChannel`, `requireAttachment` and
  `requireOpt`. For context: `requireGuildId` and `requireChannelId`.
- **New client methods.**
  - `client:login()` connects and returns once ready.
  - `client:waitFor(event, filter?, timeout?)`
  - `client:fetchMembers(guildId, options)`
  - `client:shardFor(guildId)`
  - `client:updateVoiceState(...)`
- **New events.** `shardReady`, `shardResume` and `shardDisconnect`.
- **`Discord.Env`.** Loads `.env` files; real environment variables win.
- **`Discord.Webhook`.** Posts, edits and deletes from a webhook URL alone,
  with no bot token.
- **`Discord.main(fn)`.** Prints a thrown `ApiError` from a script, which
  Lute's top level would otherwise swallow.
- **More types.**
  - Dispatch payload types: `MessageReactionAdd`, `GuildMemberEvent`,
    `GuildMembersChunk`, `PresenceUpdate` and about 25 more.
  - Common Discord types are re-exported from `@discord` (`Discord.Message`,
    `Discord.Member` and so on).
- **Transport options.** `HttpOptions.transport` and `baseUrl` for proxying
  and tests. `Gateway.Options.connect` for a custom socket.
- **Multipart forms.** `RequestOptions.form` for multipart bodies that don't
  use `payload_json`.
- **More request options.** `RequestOptions.list` (send an empty body as
  `[]`), `attachmentsPath` (attachments for nested payloads) and
  `interaction`.
- **`Embed.measure`.** Payloads now enforce the 10-embed and
  6000-character limits across a whole message.
- **`Util.color`, `Util.sleepWhile`, and array query parameters.**
- **Unit tests for `http`, `gateway` and `client`**, driven by a fake
  transport and socket. The suite is now 24 files and about 1,600 checks,
  and runs in about 15 seconds.
- **Project files.** `examples/minimal`, the `docs/` guides, `LICENSE`,
  `CONTRIBUTING.md` and a CI workflow.

### Changed

- **`ready` now fires once, when every shard is ready**, instead of once per
  shard. A single-shard bot sees no difference. Use `shardReady` for the
  per-shard signal.
- **Stricter types everywhere.** Optional Discord fields are typed optional,
  and payloads, presences and handlers no longer take `any`. Existing code
  may need narrowing, which the `require*` helpers cover.
- **`Embed.setColor` errors on a string that isn't a colour.** It used to
  fall back to blurple silently. It now accepts `#rgb` shorthand, so `#fff`
  is white rather than `0x000FFF`.
- **`Components.modal` takes `components`.** `inputs` is still accepted.
- **Every message payload is validated.** Row limits, nesting and unique
  custom ids are checked before the payload is sent.
- **Pins use the current route.** Pinning and unpinning use
  `/channels/{id}/messages/pins`. `getPins` is the new paginated listing, and
  `getPinnedMessages` is deprecated.
- **The paginator keeps a page's own components** and appends its
  navigation row after them, so V2 pages work.
- **`Client.deploy`, `login` and `run` raise plain-text errors.** A 401 gets
  a hint about resetting the token.
- **`run()` raises after a fatal close** (4004, 4014 and the like). It
  returns normally only after `stop()`. Lute exits with status 0 for an
  error raised after the main thread has yielded, so wrap `run` in
  `Discord.main` when a supervisor reads the exit status.
- **`Client.new` keeps earlier log settings.** It no longer resets the log
  level or file unless `logLevel` or `logFile` is passed.
- **`reply` and `replyEphemeral` return a second value**, true when the
  message went out as a follow-up.
- **`replyEphemeral` after a public `defer()` stays private.** It sends an
  ephemeral follow-up and removes the placeholder. Before, Discord kept the
  defer's visibility, so the content was posted publicly.
- **`guildOnly(false)` sets contexts `{0, 1}`.** Private channels (context 2)
  exist only for user-installed apps; see `userInstallable`.
- **Command options are checked against their type.** For example, `min` on
  a string option is now an error pointing to `minLength`. Subcommands can't
  be mixed with plain options at one level, and duplicate option names are
  refused.
- **Builder errors always point at the bot's own line.** They are raised at
  the first frame outside the library, which holds even where the compiler
  inlines a helper.
- **Gateway sends before authentication are queued.** Presence, voice state
  and member requests made before IDENTIFY or RESUME are flushed right
  after it, instead of being sent early and closing the socket with 4003.
- **Version and User-Agent come from one place.** They now live in
  `Const.VERSION` and `Const.REPOSITORY_URL`.

### Fixed

- **Rate limiting.**
  - Interaction callbacks kept their token in the bucket key, so memory grew
    by one bucket per interaction, forever.
  - Interaction routes queued behind the global limit, which they are exempt
    from, and could miss the 3-second deadline.
  - Webhook follow-ups for different tokens shared one bucket.
  - Channels sharing a bucket hash waited out each other's resets.
  - A per-route 429 released its bucket lock before sleeping, so queued
    requests hit the same 429.
  - A global 429 didn't hold back requests already queued on a bucket.
  - Parked waiters reset the per-second window together and went out as a
    burst.
- **Gateway.**
  - Every network drop (close 1005 or 1006) started a new session instead of
    resuming, losing events and spending an IDENTIFY.
  - A send while the socket was still dialling killed the new connection and
    leaked the socket.
  - Close codes 4007 and 4009 were treated as resumable, so a bad sequence
    looped forever.
  - After a reconnect request, a missed heartbeat ACK, or a resumable
    INVALID_SESSION, the session was lost if the runtime's close code
    arrived first.
  - Callbacks from an old socket could close the new connection.
  - A fatal close code arriving just after `onerror` was missed, so the
    shard kept retrying a bad token.
  - Heartbeats could queue behind user commands and trip zombie detection.
  - Queued shards sat on unauthenticated sockets while waiting to identify.
  - `max_concurrency` was ignored.
  - A resumable INVALID_SESSION reconnected with no delay.
  - Presence reverted to the startup presence after a re-identify.
  - The `url` from `/gateway/bot` was ignored.
- **Shutdown.**
  - `stop()` could leave the process alive for up to a minute of backoff,
    41 seconds of heartbeat wait, 120 seconds of collector timeout, a
    storage debounce, or until a scheduled job came due.
  - A fatal close on one shard left the others running.
- **Uploads and payloads.**
  - Common valid edits were refused as "message payload is empty". Examples:
    `{ components = {} }` to strip buttons, `{ embeds = {} }`, `{ flags = 4 }`,
    and forwards.
  - `components = Json.null` crashed.
  - A V2 message couldn't be edited without resending its components, and
    V2 edits were held to legacy row limits.
  - Editing with new files deleted the message's existing attachments. They
    are now kept unless you pass an `attachments` list saying which to keep.
  - File descriptions on interaction responses and forum posts were sent in
    the wrong place and lost.
  - An edit that uploaded new files dropped the attachments it meant to
    keep.
  - A quote or newline in a filename corrupted the multipart body.
  - `createInvite` and `banMember` with no options sent `[]` where Discord
    expects `{}` or no body.
- **Cache.**
  - A field cleared by an update stayed cached. For example, a lifted
    timeout still read as timed out, and a removed nickname or icon stayed.
  - A channel deleted during a guild outage stayed cached forever.
  - `GUILD_UPDATE` and `GUILD_MEMBER_UPDATE` replaced objects instead of
    patching them, losing fields like `member_count` and `joined_at`.
  - An unavailable `GUILD_CREATE` wiped a known guild.
  - Thread, emoji, sticker and self-user updates were ignored.
- **Interactions, collectors and the paginator.**
  - A handler that threw after deferring left the "thinking…" placeholder up
    forever.
  - A double-click could get past a `max = 1` collector.
  - A paginator sent as a follow-up watched the wrong message, and
    overwrote the original when it expired.
- **Storage, the scheduler and `.env`.**
  - A value set while a write was in flight was lost, even on `close()`.
  - A value that couldn't be encoded wedged the store forever.
  - A NaN delay or period made a scheduled job spin.
  - `.env` parsing got several forms wrong: a comment after a quoted value,
    a byte-order mark hiding the first key, `KEY= # comment`, and escaped
    quotes and backslashes.
- **Commands.** `bulkDeleteMessages` now refuses messages older than 14 days
  before sending, as its comment always claimed.
- **Components and payloads.**
  - Modal submits bypassed collectors.
  - custom_id length was counted in bytes, not characters.
  - A select's `defaults` weren't checked against `min`.
  - `setDisabled` disabled every child of a row, not just buttons and
    selects.
  - Builder errors blamed the library's own line instead of the caller's.
- **Linux.** Multipart uploads and `fetchMembers` failed on Linux with
  "interval is empty": `math.random(0, 0xFFFFFFFF)` overflows a C int there.
  Random tokens now come from `Util.randomHex`.
- **Missing validation.** Button, select, text input and modal title
  lengths were not checked.

## [0.2.0] - 2026-08-26

### Added

- `Discord.Storage`, a crash-durable JSON key-value store.
- `Discord.Scheduler`, cancellable one-shot and repeating jobs.

### Fixed

- `allowedMentions` in camelCase was passed through as an unknown field, so
  mentions were not suppressed.

## [0.1.0] - 2026-08-24

- Initial version: gateway, REST with rate limiting, interactions, builders,
  permissions, cache, collectors, the paginator, and the kitchen-sink example.
