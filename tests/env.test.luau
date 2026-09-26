--!strict
local Env = require("@discord/env")
local h = require("./harness")

local parsed = Env.parse([[
# a comment
DISCORD_TOKEN=abc.def
  SPACED = value with spaces
export EXPORTED=yes
DOUBLE="quoted # not a comment"
SINGLE='single'
ESCAPED="line one\nline two"
TRAILING=bare # a comment
EMPTY=
not a line at all
9BAD=skipped
]])

h.equals("plain value", parsed.DISCORD_TOKEN, "abc.def")
h.equals("whitespace around key and value is trimmed", parsed.SPACED, "value with spaces")
h.equals("export prefix is accepted", parsed.EXPORTED, "yes")
h.equals("a hash inside double quotes is kept", parsed.DOUBLE, "quoted # not a comment")
h.equals("single quotes are stripped", parsed.SINGLE, "single")
h.equals("\\n expands inside double quotes", parsed.ESCAPED, "line one\nline two")
h.equals("a trailing comment is dropped from a bare value", parsed.TRAILING, "bare")
h.equals("an empty value parses as empty", parsed.EMPTY, "")
h.equals("a key may not start with a digit", parsed["9BAD"], nil)

local env = Env.from(parsed, ".env.test")
h.equals("get reads the file", env:get("SINGLE"), "single")
h.equals("empty counts as unset", env:get("EMPTY", "fallback"), "fallback")
h.equals("missing uses the default", env:get("NOPE_NOT_SET_ANYWHERE", "d"), "d")
h.equals("flag: yes is true", env:flag("EXPORTED"), true)
h.equals("flag: missing is false", env:flag("NOPE_NOT_SET_ANYWHERE"), false)
h.throws("require names the variable", "NOPE_NOT_SET_ANYWHERE is not set", function()
	env:require("NOPE_NOT_SET_ANYWHERE")
end)
h.throws("number rejects junk rather than defaulting", "should be a number", function()
	env:number("SINGLE")
end)

-- Real environment variables win over the file. PATH is set in any shell
-- the suite runs from, so a file value for it must be ignored.
local shadow = Env.from({ PATH = "from-file" })
h.check("the environment wins over the file", shadow:get("PATH") ~= "from-file")

h.check("a missing file is not an error", Env.load("./tests/does-not-exist.env").path == nil)

-- Forms the first parser got wrong.
local tricky = Env.parse('\u{FEFF}FIRST=kept\n'
	.. 'QUOTED_COMMENT="abc" # a comment\n'
	.. 'SINGLE_COMMENT=\'lit\' # c\n'
	.. 'EMPTY_COMMENT= # nothing here\n'
	.. 'ESCAPED_QUOTE="a\\"b"\n'
	.. 'WINDOWS_PATH="C:\\\\new"\n'
	.. 'UNTERMINATED="oops\n')
h.equals("a byte-order mark does not hide the first key", tricky.FIRST, "kept")
h.equals("a comment after a double-quoted value is dropped", tricky.QUOTED_COMMENT, "abc")
h.equals("a comment after a single-quoted value is dropped", tricky.SINGLE_COMMENT, "lit")
h.equals("a value that is only a comment is empty", tricky.EMPTY_COMMENT, "")
h.equals("an escaped quote is unescaped", tricky.ESCAPED_QUOTE, 'a"b')
h.equals("an escaped backslash is not a newline", tricky.WINDOWS_PATH, "C:\\new")
h.equals("an unterminated quote is taken literally", tricky.UNTERMINATED, '"oops')

h.finish()
