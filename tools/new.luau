--!strict
--[[
	Scaffolds a new bot project that uses this library.

		git submodule add https://github.com/brandnewcrisis/lute-discord.git vendor/lute-discord
		cd vendor/lute-discord && rokit install && lute run tools/new.luau ../..

	The argument is the project directory, relative to where you run it.
	Running from inside the library is what makes rokit find `lute`: your
	project has no toolchain manifest until this writes one. With Lute on
	your PATH some other way, `lute run vendor/lute-discord/tools/new.luau .`
	from the project root works too. It writes a toolchain pin, a `.luaurc` whose `discord` alias
	points at wherever this copy of the library lives, a `.env.example`, a
	`.gitignore`, and a small bot with one command -- the shape the docs
	describe, ready for `lute run main.luau`.

	Existing files are never overwritten; they are listed and skipped, so
	running it in a half-set-up project fills in only what is missing.
]]
local fs = require("@lute/fs")
local path = require("@std/path")
local process = require("@lute/process")

local target = process.args[2]
if target == nil then
	print("usage: lute run <path-to-lute-discord>/tools/new.luau <project-directory>")
	process.exit(1)
end
assert(target ~= nil)

-- `@std/path` hands back Path objects; everything below wants strings.
local function str(value: any): string
	return path.format(value)
end

local cwd = process.cwd()
local projectDir = str(path.resolve(cwd, target))
-- This script's own location gives the library's, whichever directory it
-- was run from.
local libraryDir = str(path.dirname(path.dirname(path.resolve(cwd, debug.info(1, "s")))))
local alias = str(path.relative(projectDir, path.join(libraryDir, "src")))
if string.sub(alias, 1, 1) ~= "." and string.sub(alias, 1, 1) ~= "/" then
	alias = "./" .. alias
end

if not fs.exists(projectDir) then
	fs.mkdir(projectDir)
end

local written, skipped = {}, {}

local function write(relative: string, contents: string)
	local full = str(path.join(projectDir, relative))
	if fs.exists(full) then
		table.insert(skipped, relative)
		return
	end
	local parent = str(path.dirname(full))
	if not fs.exists(parent) then
		fs.mkdir(parent)
	end
	local handle = fs.open(full, "w")
	fs.write(handle, contents)
	fs.close(handle)
	table.insert(written, relative)
end

write(
	"rokit.toml",
	[[
# `rokit install` fetches this exact Lute. The library is tested against it.
[tools]
lute = "luau-lang/lute@1.0.0"
]]
)

write(
	".luaurc",
	table.concat({
		"{",
		'\t"languageMode": "strict",',
		'\t"aliases": {',
		`\t\t"discord": "{alias}",`,
		'\t\t"bot": "."',
		"\t}",
		"}",
		"",
	}, "\n")
)

write(
	".gitignore",
	[[
.env
*.log
data/
]]
)

write(
	".env.example",
	[[
# Copy to .env and fill in. Never commit .env.

# Developer portal -> your application -> Bot -> Reset Token.
DISCORD_TOKEN=
# A test server's id. Commands published to one server appear instantly;
# global ones can take up to an hour.
DISCORD_GUILD_ID=

# debug | info | warn | error
LOG_LEVEL=info
]]
)

write(
	"main.luau",
	[[
--!strict
-- Starts the bot: lute run main.luau
local Discord = require("@discord")

local commands = require("@bot/commands")

local env = Discord.Env.load()

local client = Discord.Client.new({
	token = env:require("DISCORD_TOKEN"),
	-- Slash commands and buttons arrive whatever intents you ask for; add
	-- more (e.g. "guildMessages") when you listen for gateway events.
	intents = { "guilds" },
	logLevel = env:get("LOG_LEVEL", "info"),
	-- Shows the error text to the user when a handler throws. Handy while
	-- developing; turn it off before inviting the bot anywhere real.
	showErrors = true,
})

client:on("ready", function(ready)
	print(`logged in as {ready.user.username}`)
end)

client:register(commands)
-- With DISCORD_GUILD_ID set, commands go to that server only, instantly.
client:deploy(nil, env:get("DISCORD_GUILD_ID"))

-- Inside Discord.main so a bad token or a missing intent exits with a
-- non-zero status and a readable message.
Discord.main(function()
	client:run()
end)
]]
)

write(
	"commands/init.luau",
	[[
--!strict
-- Every command the bot has. Add a file, require it here.
local Discord = require("@discord")

local commands: { Discord.Command } = {
	require("@bot/commands/ping"),
}

return commands
]]
)

write(
	"commands/ping.luau",
	[[
--!strict
local Discord = require("@discord")

return Discord.Commands.slash("ping", "Check the bot is alive"):handle(function(ix: Discord.Interaction)
	ix:reply("pong")
end)
]]
)

print(`project: {projectDir}`)
print(`library: {alias}`)
for _, name in written do
	print(`  wrote   {name}`)
end
for _, name in skipped do
	print(`  kept    {name} (already exists)`)
end
print("\nnext:")
print("  cp .env.example .env    # and paste your bot token")
print("  rokit install")
print("  lute run main.luau")
