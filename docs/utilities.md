# Utilities

The parts of the library that aren't about Discord's protocol but that every
real bot ends up needing: somewhere to keep state, a way to run things later,
configuration, logging, and a handful of helpers.

| Module | For |
| --- | --- |
| [`Discord.Storage`](#storage) | A JSON key-value file that survives crashes. |
| [`Discord.Scheduler`](#scheduler) | Delayed and repeating jobs you can cancel. |
| [`Discord.Env`](#env) | Configuration from the environment and `.env`. |
| [`Discord.Log`](#log) | Levelled logging, to stdout and a file. |
| [`Discord.Snowflake`](#snowflake) | Creation times from ids. |
| [`Discord.Util`](#util) | Timestamps, durations, truncation, escaping, base64. |
| [`client.cache`](#cache) | What the gateway has told the bot, in memory. |

## Storage

`Storage` is for the handful of things a bot has to remember across restarts:
tags, reaction-role mappings, a counter, pending reminders. It's one JSON
file, loaded into memory at open and written back when it changes.

```luau
local store = Discord.Storage.open("data/store.json")

store:set("greeting", "Welcome!")
print(store:get("greeting"))            -- "Welcome!"
print(store:get("missing", "default"))  -- "default"

local tags = store:table("tags")        -- created if absent
tags.rules = "Be kind."
store:touch()                           -- see below
```

| Method | Does |
| --- | --- |
| `Storage.open(path, options?)` | Loads `path`, or starts empty if it doesn't exist. |
| `store:get(key, default?)` | The value, or `default`. |
| `store:set(key, value)`, `store:delete(key)` | Change a key and schedule a write. |
| `store:has(key)`, `store:keys()` | Presence, and every key sorted. |
| `store:table(key)` | The table stored at `key`, created empty if it isn't a table. |
| `store:touch()` | Mark the store changed and schedule a write. |
| `store:flush()` | Write now. |
| `store:close()` | Write anything pending, then refuse further changes. Safe to call twice. |

Options are `{ debounce?, backup? }`: `debounce` is the number of seconds to
wait after a change before writing (default `1`, and `0` writes on every
change), and `backup` keeps a `.bak` copy (default `true`).

**Mutating a table doesn't save it.** `get` and `table` return the live
table, not a copy. The store can't see you change it, so call `touch()`
afterwards. Forgetting this is the usual cause of data that is there until
the next restart and then gone.

**Writes are coalesced.** `set` marks the store dirty and schedules one write
`debounce` seconds later, so a handler that sets twenty keys in a loop writes
once. A change made while a write is already in flight isn't lost: the store
stays dirty and the next write (or `close`) picks it up. The cost is that a
hard kill can lose the last second of changes.
Call `close()` from your shutdown path (see
[deploying.md](deploying.md#graceful-shutdown)), and use `debounce = 0` for
a small store where surviving `kill -9` matters more than the extra writes.

### What survives a crash

A bot gets killed at arbitrary points: a deploy, an out-of-memory kill, a
machine going down mid-write. The failure worth designing against isn't
losing the last change. It's losing the whole file and starting up empty,
having forgotten every tag the server ever set.

Lute has no `rename`, so the usual atomic write-and-swap isn't available.
Each write goes:

1. Write the new contents to `<path>.tmp`.
2. If the current `<path>` parses, copy it to `<path>.bak`.
3. Copy `<path>.tmp` over `<path>`.
4. Remove `<path>.tmp`.

The original is never deleted before its replacement exists. If the process
dies during step 3 and leaves `<path>` half-written, the next `open` finds
it doesn't parse, falls back to `<path>.bak`, and logs that one write was
lost. If the `.bak` is unreadable too, the broken file is copied to
`<path>.corrupt` and the store starts empty, so the evidence is kept rather
than overwritten by the next write. A `.bak` is only ever made from a file
that parses, so a corrupt file never replaces a good backup.

### What it can store

Anything that round-trips through JSON: strings, numbers, booleans, and
tables of those. Three limits come from that:

- **Keys must be strings.** Snowflakes are already strings, which is the
  right key for anything per-user or per-guild. A table with number keys
  that isn't a plain list (`{ [5] = "x" }`) can't be encoded at all, and the
  write fails with `the data cannot be saved as JSON`. With `debounce = 0`,
  the `set` that stored it throws. With a debounce, the write happens later
  on its own task, so the error appears in the log instead, and nothing is
  saved until you remove or fix the value. The store isn't wedged: the next
  write after that works. Convert number keys with `tostring` before
  storing.
- **Lists must have no holes.** `@std/json` compacts them:
  `{ [1] = "a", [3] = "c" }` is written as `["a", "c"]` and reads back as
  `{ "a", "c" }`, with `"c"` at index 2.
- **An empty table reads back as an empty table**, but it's written as `[]`.
  That only matters if another program reads the file.

The directory must exist. If it doesn't, the write fails, the error is
logged, and the store stays dirty in memory. Nothing throws.

## Scheduler

Lute has `task.delay`, but it gives you no handle, so a reminder can't be
cancelled. A throw inside the callback kills it silently, and a repeating
job built by chaining delays drifts by its own runtime. `Scheduler` fixes
all three.

```luau
local scheduler = Discord.Scheduler.new()

local id = scheduler:after(30, function()
	client:send(channelId, "Thirty seconds are up.")
end, "countdown")

scheduler:every(300, function()
	client:setPresence(Discord.Client.presence("watching", `{client.cache:stats().guilds} servers`))
end, "presence", true) -- true: run once now, then every 300 s

scheduler:cancel(id)
```

| Method | Does |
| --- | --- |
| `scheduler:after(delay, fn, label?)` | Runs `fn` once, `delay` seconds from now. |
| `scheduler:every(period, fn, label?, immediate?)` | Runs `fn` every `period` seconds, first after one period, or straight away with `immediate`. |
| `scheduler:at(unixSeconds, fn, label?)` | Runs `fn` at a wall-clock time. A time in the past runs straight away. |
| `scheduler:cancel(id)` | Cancels a job. Returns false if it had already run or been cancelled. Safe to call from inside the job. |
| `scheduler:timeUntil(id)` | Seconds until the job next runs, or `nil`. |
| `scheduler:count()` | Pending jobs. |
| `scheduler:stop()` | Cancels everything and refuses new jobs. |

All three scheduling methods return a numeric job id. `label` names the job
in log lines. A delay or period that is NaN or infinite is an error, as is a
period of zero or less: a computed delay like `tonumber(value) / rate` is
the usual way to get one, and a NaN due time would otherwise make the job
spin.

**Throws are contained.** Each run is wrapped in `xpcall`. A throw is logged
with its traceback, and a repeating job keeps its schedule.

**Repeats don't drift.** `every` schedules each run against the time the job
started, not against when the previous run finished, so a job that takes two
seconds still runs on the minute. If one run takes longer than a whole
period, the missed ticks are skipped rather than fired back to back.

**Cancelling releases the process.** A Lute timer can't be cancelled, and a
pending one keeps the process alive until it fires. A plain
`task.delay(86400, ...)` would hold a stopped bot open for a day. The
scheduler waits in quarter-second slices and checks whether the job is
still wanted, so `cancel` and `stop` take effect within a quarter second.

**Jobs live in memory.** They don't survive a restart, by design: what "the
bot was down when this was due" should mean depends on the job. A reminder
should fire late; a "post the daily puzzle at 9:00" job should probably be
skipped. So persist the due time yourself, and re-arm on startup. The
[example below](#example-reminders-that-survive-a-restart) does exactly
that.

## Example: reminders that survive a restart

`/remind` stores each reminder in `Storage` with an absolute due time, and
schedules it with `Scheduler:at`. On startup, every stored reminder is
re-armed, and because `at` runs past times immediately, anything that fell
due while the bot was down is delivered as soon as it's back.

```luau
--!strict
local process = require("@lute/process")

local Discord = require("@discord")
local Commands = Discord.Commands
local Log = Discord.Log
local Util = Discord.Util

local env = Discord.Env.load()
local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	intents = { "guilds" },
	logFile = env:get("LOG_FILE"),
})

local store = Discord.Storage.open("data/reminders.json")
local scheduler = Discord.Scheduler.new()

type Reminder = { channelId: string, userId: string, text: string, dueAt: number }

-- Reminder id -> scheduler job id, so a reminder could be cancelled later.
local jobs: { [string]: number } = {}

local function arm(id: string, reminder: Reminder)
	jobs[id] = scheduler:at(reminder.dueAt, function()
		local ok, err = pcall(function()
			client:send(reminder.channelId, {
				content = `<@{reminder.userId}> reminder: {Util.escapeMarkdown(reminder.text)}`,
				allowedMentions = Discord.Payload.allowedMentions({ userIds = { reminder.userId } }),
			})
		end)
		if not ok then
			Log.warn(`reminder {id} could not be delivered: {tostring(err)}`)
		end
		-- Delivered or undeliverable, it's done: forget it.
		local all = store:table("reminders")
		all[id] = nil
		store:touch()
		jobs[id] = nil
	end, `reminder {id}`)
end

client:command("remind", function(ix: Discord.Interaction)
	local minutes = ix:requireOpt("minutes") :: number
	local text = ix:requireOpt("text") :: string
	-- The interaction id is a snowflake: unique, and already a string.
	local id = ix.id

	local reminder: Reminder = {
		channelId = ix:requireChannelId(),
		userId = ix.user.id,
		text = text,
		dueAt = Util.unix() + minutes * 60,
	}
	local all = store:table("reminders")
	all[id] = reminder
	store:touch()
	arm(id, reminder)

	ix:replyEphemeral(`I'll remind you {Util.timestamp(reminder.dueAt, "R")}.`)
end)

-- Re-arm whatever was pending when the bot last stopped.
for id, reminder in store:table("reminders") do
	arm(id, reminder :: Reminder)
end

client:deploy({
	Commands.slash("remind", "Remind you later")
		:integerOption("minutes", "In how many minutes", { required = true, min = 1, max = 10080 })
		:stringOption("text", "What to remind you about", { required = true, maxLength = 200 }),
}, env:get("DISCORD_GUILD_ID"))

-- `run` returns after `client:stop()`, and raises if the bot can't stay
-- connected. Caught so the cleanup runs and the exit status says so.
local ok, err = pcall(client.run, client)
scheduler:stop()
store:close()
if not ok then
	Log.error(tostring(err))
	process.exit(1)
end
```

Some details worth copying:

- **Store the absolute time, not the delay.** `dueAt` is a unix timestamp,
  so it means the same thing after a restart.
- **Re-arming before `run` is fine.** A reminder that's already overdue
  fires as soon as the scheduler gets a turn, which may be before the
  gateway connects. That still works: sending a message is a REST call and
  doesn't need the gateway.
- **The reminder is removed whether or not delivery worked.** A channel the
  bot can no longer post in would otherwise fail on every restart forever.
- **Pings are limited to the one user.** The text is user input, so it's
  escaped, and `allowedMentions` stops it pinging anyone else.

## Env

`Env` reads configuration from environment variables, with a `.env` file as
a fallback. Lute has no dotenv, and a token doesn't belong on the command
line, where it ends up in shell history and `ps`.

```luau
local env = Discord.Env.load()

local token = env:require("DISCORD_TOKEN")          -- throws if unset
local guildId = env:get("DISCORD_GUILD_ID")         -- string?
local level = env:get("LOG_LEVEL", "info")          -- with a default
local privileged = env:flag("PRIVILEGED_INTENTS")   -- boolean
local port = env:number("PORT", 8080)               -- number?, throws if not numeric
```

| Function | Does |
| --- | --- |
| `Env.load(path?)` | Reads `path`, default `.env` in the **current working directory**. A missing file isn't an error; in production there usually isn't one. |
| `Env.from(values, path?)` | An `Env` over a table you already have, for tests. |
| `env:get(name, default?)` | The value, or `default`. |
| `env:require(name)` | The value, or an error naming the variable and where it looked. |
| `env:flag(name)` | True for `1`, `true`, `yes` or `on`, in any case. False otherwise, including unset. |
| `env:number(name, default?)` | The value as a number, or `default` when unset. Set but not numeric is an error, because silently using the default would hide a typo. |
| `Env.parse(text)` | The parser on its own: text to a table. |

**The real environment wins.** A variable set in the process environment
takes precedence over the same name in `.env`. That lets one checkout run on
a laptop with a `.env` and in a container that injects secrets as variables,
without either knowing about the other.

**Empty means unset, in both places.** `.env.example` files are full of
`KEY=` lines, and treating those as real empty strings turns a missing
token into a 401 that doesn't say which variable was blank. One consequence:
an empty environment variable doesn't override a value in `.env`. It falls
through to it.

The file format is `KEY=value` lines, following what dotenv tools agree on.
Blank lines and `#` comments are skipped, a leading `export ` is allowed,
and a UTF-8 byte-order mark at the start of the file is skipped (Windows
editors add one, and it would otherwise hide the first key). Double-quoted
values understand `\n`, `\r`, `\t`, `\"` and `\\`, decoded in one pass, so
`\\n` is a backslash followed by `n`. Single-quoted values are taken
literally. Either kind may be followed by a comment, and a value with no
closing quote is taken literally, quote included. An unquoted value ends at
` #`, and one that starts with `#` is empty, so `KEY= # comment` is unset.
Lines that don't parse are ignored, because the file is edited by hand.

Because the default path is relative, a bot started from another directory
(by systemd, say) won't find its `.env`. Set the working directory, or pass
an absolute path.

## Log

A small levelled logger that the whole library shares. Lines go to stdout
and, optionally, to a file:

```text
2026-09-26 14:02:31 INFO	[mybot] shard 0: resumed
```

The date and time are UTC. The date is there because a bot's log outlives
the day it started, and a bare time can't say which night the crash was.
The bracketed prefix is set to the bot's username when it connects.

| Function | Does |
| --- | --- |
| `Log.debug(msg)`, `Log.info(msg)`, `Log.warn(msg)`, `Log.error(msg)` | Log a string at that level. |
| `Log.setLevel(level)` | `"debug"`, `"info"`, `"warn"` or `"error"`. Anything else means `"info"`. |
| `Log.setFile(path?)` | Also append every line to `path`. `nil` turns the file off. |
| `Log.setPrefix(text?)` | A tag printed before every message. |
| `Log.enabled(level)` | Whether a level would print. Guard expensive messages with it. |
| `Log.setHook(fn?)` | Also call `fn(level, message)` for every line that passes the level. `nil` removes it. |

**Why the file matters.** Lute block-buffers stdout whenever it isn't
attached to a terminal, which is every way a bot runs for real: under
`nohup`, in a container, under systemd. Lines sit in the buffer until it
fills, so a bot that died an hour ago shows an empty log, just when you
need one. The file sink writes each line straight to disk. See
[deploying.md](deploying.md#logs).

The file is opened, appended to and closed for every line. That's slower
than holding it open, but it means log rotation that moves the file away
just works: the next line creates a new one. A failure to write the file is
ignored, because logging should never be what takes a bot down.

**Hooking the log.** `Log.setHook(fn)` calls `fn(level, message)` after
each line is printed, for every line at or above the current level. `level`
is `"debug"`, `"info"`, `"warn"` or `"error"`, and `message` is the text
alone, without the timestamp, level or prefix. Use it to forward warnings
to a log channel or an error tracker, or in a test, to assert that a
warning was given. A hook that throws is ignored. There's one hook at a
time, and setting another replaces it.

The hook runs inside whatever code logged, so hand slow work off to its own
task. And if it sends to Discord, skip the REST layer's own lines (retries
and rate limits, which start with an HTTP method or mention "rate
limited"): a send that gets rate limited would log, and the hook would send
that line too.

```luau
local task = require("@lute/task")

local LOG_CHANNEL = "123456789012345678"

Log.setHook(function(level, message)
	if level ~= "warn" and level ~= "error" then
		return
	end
	if string.find(message, "rate limited", 1, true) or string.find(message, "^%u+ /") then
		return
	end
	task.spawn(pcall, client.send, client, LOG_CHANNEL, `**{level}** {string.sub(message, 1, 1900)}`)
end)
```

`Client.new` sets the level and file from its `logLevel` and `logFile`
options, but only the ones you pass. Leave one out and whatever you set
earlier with `Log.setLevel` or `Log.setFile` stays in place. The level
starts as `"info"`.

## Snowflake

Discord ids are 64-bit numbers sent as strings, and they must stay strings:
`tonumber` rounds them, and a rounded id is a wrong id that still looks
plausible. Every id encodes when the object was created, and `Snowflake`
reads it with string arithmetic so the low bits never pass through a float.

| Function | Returns |
| --- | --- |
| `Snowflake.timestamp(id)` | Unix seconds (with milliseconds as the fraction) when the object was created. |
| `Snowflake.isoDate(id)` | That time as `"2016-04-30 11:18:25 UTC"`. |
| `Snowflake.age(id)` | Seconds since creation. |
| `Snowflake.fromTimestamp(unixSeconds)` | A synthetic id for that time, usable as a `before`/`after` cursor when paging messages. |
| `Snowflake.isValid(value)` | Whether `value` looks like an id: a string of 15 to 21 digits. |

```luau
-- Account age, as Discord's relative timestamp.
local created = Discord.Snowflake.timestamp(user.id)
ix:reply(`Account created {Discord.Util.timestamp(created, "R")}`)

-- Messages from the last hour, whatever their ids.
local recent = api.channels.getMessages(channelId, {
	after = Discord.Snowflake.fromTimestamp(Discord.Util.unix() - 3600),
	limit = 100,
})
```

`Snowflake.age` is how you'd pre-filter messages for
`channels.bulkDeleteMessages`. Discord refuses anything older than 14 days
(`14 * 86400` seconds), and the library checks that before sending, with a
minute's margin for clock skew, and says how many ids were too old.

## Util

| Function | Does |
| --- | --- |
| `Util.timestamp(unixSeconds, style?)` | Discord's `<t:…>` markup, shown in each viewer's own timezone. Style `t` short time, `T` long time, `d` short date, `D` long date, `f` date and time (the default), `F` with weekday, `R` relative ("in 5 minutes"). |
| `Util.duration(seconds)` | The two largest non-zero units: `"2d 4h"`, `"1h 1m"`, `"0s"`. |
| `Util.truncate(text, limit)` | At most `limit` characters, with the ellipsis counted inside the limit. Counts UTF-8 characters, not bytes. |
| `Util.escapeMarkdown(text)` | Escapes backslash, `*`, `_`, `~`, backtick, `\|` and `>`, so user text can't add formatting or start a block quote. It doesn't stop mentions; use `allowedMentions` for that ([rest.md](rest.md#mentions)). |
| `Util.dataUri(mime, bytes)` | A `data:` URI, the form image fields like emoji and avatars take. |
| `Util.base64(bytes)` | Standard padded base64 of a string or buffer. |
| `Util.color(value)` | An RGB integer from a number, a `Discord.Color` entry, `"#rrggbb"` or `"#rgb"`, or `nil` if it isn't a colour. |
| `Util.sleepWhile(seconds, keepGoing, slice?)` | Sleeps up to `seconds`, waking early when `keepGoing()` returns false. Returns true if the full time passed. |
| `Util.backoff(attempt, base?, cap?)` | A random delay between 0 and `min(cap, base * 2^attempt)`. Defaults 1 and 60. |
| `Util.unix()` | Wall-clock unix seconds. For timestamps Discord will show. |
| `Util.now()`, `Util.since(instant)` | A monotonic instant, and seconds since one. For measuring durations. |

**Two clocks.** `Util.unix()` is the wall clock and jumps when the machine
syncs its time. `Util.now()` never moves backwards. Use the first for
anything you show or store (due times, embed timestamps) and the second for
anything you measure (timeouts, latency).

**`sleepWhile` is how to wait for something stoppable.** Lute timers can't
be cancelled, so a long `task.wait` inside a loop that should end on
shutdown keeps the process alive until it expires. Waiting in slices and
checking a condition lets the loop end promptly:

```luau
while client.running do
	postDailyStats()
	-- Sleeps an hour, but returns within a quarter second of client:stop().
	Util.sleepWhile(3600, function(): boolean
		return client.running
	end)
end
```

`Util` seeds `math.random` from the operating system's random source when
it loads. Lute leaves it unseeded, which means every process draws the same
sequence. That matters: several shards restarting together would otherwise
all "randomly" reconnect at the same moment.

## Cache

With the default `cache = true`, the client keeps an in-memory copy of the
guilds, channels, threads, roles and members the gateway has sent it. It's
what makes permission checks free rather than three REST calls each.

| Accessor | Returns |
| --- | --- |
| `cache:getGuild(guildId)` | `Guild?` |
| `cache:getChannel(channelId)` | `Channel?`, threads included |
| `cache:getRoles(guildId)` | `{ [roleId]: Role }`, empty if unknown |
| `cache:getRole(guildId, roleId)` | `Role?` |
| `cache:getMember(guildId, userId)` | `Member?`, only members seen in events |
| `cache:getUser(userId)` | `User?` |
| `cache:stats()` | Counts of each, for a `/stats` command |
| `cache.self` | The bot's own user |

Members aren't fully cached. Filling that would need the `guildMembers`
privileged intent and unbounded memory, so `getMember` knows only members
the bot has seen: in the initial guild data, messages, interactions, joins,
member updates and `client:fetchMembers` results.
When it returns `nil`, fall back to `client.api.guilds.getMember`. The
objects are the live cached tables, so read them but don't modify them.

[events.md](events.md) covers which events keep the cache current and what
turning it off (`cache = false`) changes.
