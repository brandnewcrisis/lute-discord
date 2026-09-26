--!strict
--[[
	Configuration from the environment, with a `.env` file as fallback.

		local env = Discord.Env.load()
		local token = env:require("DISCORD_TOKEN")
		local guildId = env:get("DISCORD_GUILD_ID")

	Lute has no dotenv, and a bot token does not belong on a command line --
	it lands in shell history and in `ps` -- so the file is parsed here.

	Real environment variables win over the file. That is what lets the same
	checkout run on a laptop with a `.env` and in a container that injects
	secrets as variables, without either one needing to know about the other.

	An empty value counts as unset in both places. `.env.example` files are
	full of `KEY=` lines, and treating those as a real empty string turns a
	missing token into a 401 with no hint about which variable was blank.
]]
local fs = require("@lute/fs")
local process = require("@lute/process")

local Env = {}
Env.__index = Env

export type Env = typeof(setmetatable(
	{} :: {
		--- Values read from the file. `get` consults the real environment first.
		file: { [string]: string },
		--- The file that was read, or nil if there was none.
		path: string?,
	},
	{} :: typeof(Env)
))

--[[
	Decodes the inside of a double-quoted value in one left-to-right pass,
	so `\\n` (an escaped backslash, then `n`) does not become a newline.
	Returns the value and whether the closing quote was found.
]]
local function doubleQuoted(text: string): (string, boolean)
	local out = {}
	local index = 1
	while index <= #text do
		local char = string.sub(text, index, index)
		if char == '"' then
			return table.concat(out), true
		elseif char == "\\" and index < #text then
			local nextChar = string.sub(text, index + 1, index + 1)
			local escapes: { [string]: string } = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\" }
			table.insert(out, escapes[nextChar] or ("\\" .. nextChar))
			index += 2
		else
			table.insert(out, char)
			index += 1
		end
	end
	return table.concat(out), false
end

--[[
	Parses `.env` text: `KEY=value` lines, `#` comments, an optional leading
	`export `, and quoted values. Anything that is not a `KEY=` line is
	ignored rather than rejected, because the file is hand-edited.

	Quoting follows what dotenv tools agree on. Double quotes understand
	`\n`, `\t`, `\"` and `\\`; single quotes are literal; either may be
	followed by a comment. An unquoted value ends at ` #`, and one that
	starts with `#` is empty. A UTF-8 byte-order mark -- which Windows
	editors like to add -- is skipped, since it would otherwise glue itself
	to the first key and hide it.
]]
function Env.parse(contents: string): { [string]: string }
	local out: { [string]: string } = {}
	if string.sub(contents, 1, 3) == "\u{FEFF}" then
		contents = string.sub(contents, 4)
	end
	for line in string.gmatch(contents, "[^\r\n]+") do
		local trimmed = string.match(line, "^%s*(.-)%s*$") :: string
		if trimmed == "" or string.sub(trimmed, 1, 1) == "#" then
			continue
		end
		trimmed = string.gsub(trimmed, "^export%s+", "")
		local key, raw = string.match(trimmed, "^([%a_][%w_]*)%s*=%s*(.*)$")
		if key == nil or raw == nil then
			continue
		end
		local text = raw :: string
		local first = string.sub(text, 1, 1)
		local value: string
		if first == '"' then
			local decoded, closed = doubleQuoted(string.sub(text, 2))
			-- An unterminated quote is taken literally rather than guessed at.
			value = if closed then decoded else text
		elseif first == "'" then
			value = string.match(text, "^'([^']*)'") or text
		elseif first == "#" then
			value = ""
		else
			value = string.match(text, "^(.-)%s+#.*$") or text
		end
		out[key] = value
	end
	return out
end

--- Reads `path` (default `.env`, relative to the working directory). A
--- missing file is not an error: in production there usually is none.
function Env.load(path: string?): Env
	local target = path or ".env"
	local file: { [string]: string } = {}
	local found: string? = nil
	if fs.exists(target) then
		local handle = fs.open(target, "r")
		local contents = fs.read(handle)
		fs.close(handle)
		file = Env.parse(contents)
		found = target
	end
	return Env.from(file, found)
end

--- An `Env` over values you already have -- for tests, or for config that
--- arrives some other way. The real environment still wins over them.
function Env.from(values: { [string]: string }, path: string?): Env
	return setmetatable({ file = values, path = path }, Env)
end

--- The value, or `default` when it is unset or empty.
function Env.get(self: Env, name: string, default: string?): string?
	local value = process.env[name]
	if value == nil or value == "" then
		value = self.file[name]
	end
	if value == nil or value == "" then
		return default
	end
	return value
end

--- The value, or an error naming the variable and where it was looked for.
function Env.require(self: Env, name: string): string
	local value = Env.get(self, name)
	if value == nil then
		local where = if self.path ~= nil
			then `the environment or {self.path}`
			else "the environment (and there is no .env file)"
		error(`{name} is not set in {where}`, 2)
	end
	return value
end

--- `1`, `true`, `yes` and `on` (any case) are true; anything else is false.
function Env.flag(self: Env, name: string): boolean
	local value = Env.get(self, name)
	if value == nil then
		return false
	end
	local lowered = string.lower(value)
	return lowered == "1" or lowered == "true" or lowered == "yes" or lowered == "on"
end

--- The value as a number, or `default` when unset. A value that is set but
--- not numeric is an error: silently falling back would hide a typo.
function Env.number(self: Env, name: string, default: number?): number?
	local value = Env.get(self, name)
	if value == nil then
		return default
	end
	local parsed = tonumber(value)
	if parsed == nil then
		error(`{name} should be a number, got "{value}"`, 2)
	end
	return parsed
end

return Env
