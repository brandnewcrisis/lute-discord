# Deploying

Running a bot on your laptop and running it for real differ in a few ways
that bite: stdout disappears, the process gets restarted without you
watching, and restarting too often has a cost Discord enforces. This page
covers each, with a systemd unit and a Dockerfile to start from.

## A production `main.luau`

Most of this page comes back to a few lines at the start and end of your
entry point:

```luau
--!strict
local process = require("@lute/process")

local Discord = require("@discord")

local env = Discord.Env.load()

local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	intents = { "guilds" },
	logLevel = env:get("LOG_LEVEL", "info"),
	logFile = env:get("LOG_FILE"),                 -- see "Logs"
})
local store = Discord.Storage.open("data/store.json")
local scheduler = Discord.Scheduler.new()

-- ... register commands, components and events here ...

-- Blocks until client:stop(). Raises if the bot can't stay connected.
local ok, err = pcall(client.run, client)

scheduler:stop()                                   -- see "Graceful shutdown"
store:close()
if not ok then
	local message = tostring(err)
	Discord.Log.error(message)
	-- 78: a fatal close such as a bad token; see "Restarts".
	process.exit(if string.find(message, "could not stay connected:", 1, true) == 1 then 78 else 1)
end
```

Commands aren't deployed here. See
[Deploying commands from CI](#deploying-commands-from-ci).

## Secrets and configuration

The token is the whole credential: anyone who has it can log in as your
bot. Keep it out of the repository.

- **`.env` is for your machine.** Put it in `.gitignore` before you create
  it, and commit a `.env.example` with the keys and empty values instead.
- **In production, use real environment variables.** `Env` gives the
  process environment precedence over `.env`
  ([utilities.md](utilities.md#env)), so the same code reads a `.env` on
  your laptop and injected variables on a server, with no flag to switch
  between them. systemd's `EnvironmentFile=` and Docker's `--env-file` both
  take the same `KEY=value` format.
- **`Env.load()` looks in the working directory.** A service started from
  `/` won't find a `.env` in your project folder. Set the working directory
  (both examples below do).
- **If the token leaks, reset it** in the developer portal under **Bot >
  Reset Token**. The old one stops working at once.

## Logs

Lute block-buffers stdout when it isn't attached to a terminal, which is
every way a bot runs in production: under `nohup`, systemd, Docker, or with
output piped to a file. Lines sit in a buffer until it fills. A bot that
crashed an hour ago can show an empty log, and `journalctl` or `docker logs`
lag far behind what's happening.

So give the logger a file. Set `LOG_FILE` and pass it to `Client.new` as
`logFile` (as above). Every line is then appended to that file as it's
logged, as well as printed. The file is reopened for each line, so rotating
it with `logrotate` (or anything that moves the file away) needs no signal
or restart: the next line creates a new file.

Your own `print` calls are still buffered. Use `Discord.Log` for anything
you'll want to read later.

## `client:run()` and `client:login()`

Both connect every shard. They differ in when they return:

| | Returns | On a fatal close (bad token, disallowed intents) |
| --- | --- | --- |
| `client:run()` | Only when `client:stop()` is called. | Stops every shard and raises `could not stay connected: <reason>`. |
| `client:login()` | Once every shard is ready (when `ready` fires). The shards keep running in the background. | Raises `could not connect: <reason>`. |

Use `run` for a normal bot. Use `login` when you want to do something once
connected and then carry on with your own loop, such as a script that
connects, posts, and stops:

```luau
client:login()
client:send(channelId, "Online")
client:stop()
```

Both refuse to start when the session budget can't cover the shard count
(see the next section), and both raise startup failures as plain text rather
than an error object, so they're readable in a log without `Discord.main`.

**Catch the error from `run()` yourself.** In Lute 1.0.0, an error that
reaches the top level after the main thread has been resumed from a
`task.wait` ends the process with exit status **0**. `run()` waits on the
gateway in a `task.wait` loop, so its error always lands in that case, and a
bare `client:run()` that hits a bad
token prints the error and exits as if it had succeeded, and a supervisor
neither restarts nor alerts. Wrap it in `pcall` and exit with a code of your
choosing, as the `main.luau` above does, or run it inside `Discord.main`,
which logs the error and exits with status 1:

```luau
Discord.main(function()
	client:run()
end)
```

The same goes for `login()`.

## Restarts and the session budget

Every fresh gateway connection starts with an IDENTIFY, and Discord allows a
bot a fixed number of them per day: typically 1000, across all shards.
Resuming a dropped session doesn't count, but every process start does,
because the session lives in memory. Discord's documentation says that
using up the budget terminates the bot's sessions and **resets its token**.
A bot stuck in a crash loop with a fast restart can get there in an
afternoon.

`client:run()` and `client:login()` check this before connecting. They call
`GET /gateway/bot` and log what it says:

```text
INFO	gateway: 1 shard(s), 997/1000 session starts left, max concurrency 1
```

If fewer starts remain than there are shards to start, they refuse to
connect and raise an error saying when the budget resets, rather than
burning the rest of it. You can check the same numbers yourself with
`client.api.gateway.getBot().session_start_limit`: `total`, `remaining`,
`reset_after` (milliseconds) and `max_concurrency`.

What that means for your supervisor:

- **Restart with a delay.** `RestartSec=10` in systemd, not the default
  100 ms. A delay of seconds costs nothing on a real crash and turns a
  crash loop from thousands of attempts into dozens.
- **Cap the retries.** systemd's `StartLimitBurst` and Docker's
  `--restart on-failure:5` stop a loop that isn't going to fix itself.
- **Don't restart on configuration errors.** A wrong token or a privileged
  intent you haven't enabled fails the same way every time. The `main.luau`
  above exits with status 78 when `run()` raises `could not stay
  connected: ...`, which it does only for a fatal close code, and the
  systemd unit below tells systemd not to restart on 78. Fix the
  configuration, then start it by hand.

Other close codes (network drops such as 1006, Discord restarting a gateway
node) never reach your supervisor at all. Each shard reconnects and resumes
by itself, with backoff. A shard starts a fresh session, spending one IDENTIFY, only when Discord ends the
session: a server close with 1000, 1001, 4007 or 4009
(`Const.SESSION_ENDING_CLOSE_CODES`), or an INVALID_SESSION that says it
can't be resumed.

## A systemd unit

This assumes a `mybot` user with rokit installed in its home, and the
project (including its `rokit.toml`) in `/opt/mybot`. The rokit shim picks
the Lute version from the `rokit.toml` in the working directory, so
`WorkingDirectory` has to point at the project.

```ini
# /etc/systemd/system/mybot.service
[Unit]
Description=mybot Discord bot
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
User=mybot
WorkingDirectory=/opt/mybot
ExecStart=/home/mybot/.rokit/bin/lute run main.luau

# Secrets: DISCORD_TOKEN=... in a root-owned file, mode 600.
EnvironmentFile=/etc/mybot.env
# Creates /var/log/mybot owned by the service user.
LogsDirectory=mybot
Environment=LOG_FILE=/var/log/mybot/bot.log

Restart=on-failure
RestartSec=10
# 78 = main.luau's "fatal configuration error": don't loop on it.
RestartPreventExitStatus=78

[Install]
WantedBy=multi-user.target
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mybot
tail -f /var/log/mybot/bot.log
```

If you prefer the state outside the project, `StateDirectory=mybot` creates
`/var/lib/mybot` for you. Point `Storage.open` there with an absolute path.

## A Dockerfile

> **This is a template.** It's written to be conventional, but it isn't
> built or tested in this project's CI. Check it before relying on it.

```dockerfile
# Template -- not built or tested in CI.
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git unzip \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home bot
USER bot
WORKDIR /home/bot/app

# rokit, then the Lute version pinned in the project's rokit.toml.
RUN curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | bash
ENV PATH="/home/bot/.rokit/bin:${PATH}"
COPY --chown=bot:bot rokit.toml ./
RUN rokit install --no-trust-check

# The project, including vendor/lute-discord. Run
# `git submodule update --init` before building.
COPY --chown=bot:bot . .

RUN mkdir -p data
VOLUME /home/bot/app/data
ENV LOG_FILE=/home/bot/app/data/bot.log

CMD ["lute", "run", "main.luau"]
```

Add a `.dockerignore` so the image never contains your secrets or local
state:

```text
.env
data/
.git/
```

Run it with the token injected and the data directory on a volume:

```bash
docker build -t mybot .
docker run -d --name mybot --env-file /etc/mybot.env \
  -v mybot-data:/home/bot/app/data --restart on-failure:5 mybot
```

`docker logs` shows stdout, which is buffered, so read the log file in the
volume instead: `docker exec mybot tail -f data/bot.log`.

## Graceful shutdown

`client:stop()` closes every shard and makes `run()` return. Anything after
`run()` then gets its turn, which is where the rest of your cleanup goes:

1. `scheduler:stop()` cancels pending jobs, so nothing fires midway through
   shutdown.
2. `store:close()` writes any change still waiting out its debounce, and
   refuses further writes.

Stop the scheduler first. A job that runs after the store is closed would
fail to save.

**Lute has no signal handlers.** `SIGTERM` from `systemctl stop` or
`docker stop` ends the process immediately, and nothing after `run()`
executes. Storage is built to survive that: the file on disk is always a
complete version, and what can be lost is the last `debounce` seconds of
changes (one second by default). If that matters, use `debounce = 0` for
the important store. For planned restarts, an owner-only `/shutdown`
command that calls `client:stop()` lets the cleanup run.

**Why the process exits at all.** A Lute timer can't be cancelled, and a
pending one keeps the process alive until it fires. A heartbeat parked in a
41-second wait would hold a stopped bot open for 41 seconds, and a reminder
scheduled with `task.delay` for tomorrow would hold it open until tomorrow.
So every long wait in the library is sliced: the heartbeat, reconnect
backoff, the store's debounce and every scheduler job wake several times a
second to check whether they're still wanted, and end within a fraction of a
second of `stop`. Your own code has to do the same. A `task.wait(600)` in a
loop, or a long `task.delay`, keeps the process running after `run()`
returns. Use [`Util.sleepWhile`](utilities.md#util) or the
[`Scheduler`](utilities.md#scheduler) instead.

## Sharding

A gateway connection (a shard) can carry at most 2500 guilds. Past that,
Discord closes it with 4011, and a bot has to split its guilds across
several.

**By default this is automatic.** With no `shardCount` option, the client
starts as many shards as `GET /gateway/bot` recommends, all in the same
process. A small bot gets one, and you never think about it.

**`shardCount` fixes the number.** Set it when you want headroom before
Discord's recommendation grows, or a count that stays the same across
restarts:

```luau
local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	intents = { "guilds" },
	shardCount = env:number("SHARD_COUNT"), -- nil means "ask Discord"
})
```

All shards run in the one process. There's no option to run a subset of
shards per process.

**Startup is paced by `max_concurrency`.** Discord allows one IDENTIFY per
five seconds in each *identify bucket*, and a shard's bucket is
`shard_id % max_concurrency`. Most bots have `max_concurrency` 1, so shards
connect one after another about five seconds apart (the client uses 5.2 s,
for clock skew). Large bots get 16 or more, and that many shards connect in
parallel. The client reads the value from `/gateway/bot` and paces itself
per bucket: it spaces the dials, so a shard waiting its turn isn't holding an
unauthenticated socket open, and checks the slot again right before each
IDENTIFY goes out, because handshakes take variable time and a slow one
followed by a fast one would otherwise land two IDENTIFYs too close. So a
16-shard bot with concurrency 1 takes about 80 seconds to come fully
online, and with concurrency 16, about 5.

**Which shard has a guild?** `client:shardFor(guildId)` returns
`(guild_id >> 22) % shardCount`, computed on the id string so it's exact.
Shards are `client.shards[shardFor(guildId) + 1]`. DMs always arrive on
shard 0. You rarely need this: `client:fetchMembers` and
`client:updateVoiceState` route to the right shard for you.

**Events.** `ready` fires once, when every shard has connected.
`shardReady`, `shardResume` and `shardDisconnect` report each shard on its
own. See [events.md](events.md).

## Deploying commands from CI

Publishing the command set on every start is convenient while you
develop, but for a running bot, make it a release step instead. A restart
shouldn't be a schema change, a crash loop shouldn't hit the commands route
on every attempt, and a global publish takes up to an hour to spread, so you
want it to happen once, on purpose.
[commands.md](commands.md#deploying-from-ci) has the pattern: the command
definitions in their own module, shared by the bot and a small `deploy.luau`
that publishes them and exits. `deploy` is REST-only, so it doesn't open a
gateway connection or disturb the running bot.

In a pipeline, run it with the token from the CI system's secret store:

```yaml
- name: Publish slash commands
  run: lute run deploy.luau
  env:
    DISCORD_TOKEN: ${{ secrets.DISCORD_TOKEN }}
```

A failure exits non-zero, which fails the job.
