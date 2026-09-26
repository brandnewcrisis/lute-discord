--!strict
local Util = require("@discord/util")
local h = require("./harness")

-- RFC 4648 test vectors.
for _, case in { { "", "" }, { "f", "Zg==" }, { "fo", "Zm8=" }, { "foo", "Zm9v" }, { "foob", "Zm9vYg==" }, { "fooba", "Zm9vYmE=" }, { "foobar", "Zm9vYmFy" } } do
	h.equals(`base64 "{case[1]}"`, Util.base64(case[1]), case[2])
end
h.check("base64 handles every byte value", (function()
	local all = buffer.create(256)
	for index = 0, 255 do
		buffer.writeu8(all, index, index)
	end
	local encoded = Util.base64(all)
	return #encoded == 344 and string.match(encoded, "^[A-Za-z0-9+/=]+$") ~= nil
end)())
h.check("data uri", string.sub(Util.dataUri("image/png", "foo"), 1, 22) == "data:image/png;base64,")

h.equals("truncate leaves short text", Util.truncate("abc", 10), "abc")
h.equals("truncate adds an ellipsis inside the budget", utf8.len(Util.truncate(string.rep("a", 50), 10)), 10)
h.equals("truncate counts characters, not bytes", Util.truncate("\u{00e9}\u{00e9}\u{00e9}", 5), "\u{00e9}\u{00e9}\u{00e9}")

h.equals("query is empty for nil", Util.query(nil), "")
h.equals("query skips nils", Util.query({ a = 1, b = nil }), "?a=1")
h.equals("query is sorted and encoded", Util.query({ b = "x y", a = 1 }), "?a=1&b=x%20y")

h.equals("encodeComponent escapes", Util.encodeComponent("a#b/c"), "a%23b%2Fc")
h.equals("encodeComponent leaves unreserved", Util.encodeComponent("a-b_c.d~e"), "a-b_c.d~e")

h.equals("markdown escaping", Util.escapeMarkdown("**bold**"), "\\*\\*bold\\*\\*")
h.equals("block quotes escaped too", Util.escapeMarkdown("> quote"), "\\> quote")

h.equals("duration seconds", Util.duration(45), "45s")
h.equals("duration two units", Util.duration(3661), "1h 1m")
h.equals("duration days", Util.duration(90000), "1d 1h")

h.equals("timestamp markup", Util.timestamp(1700000000, "R"), "<t:1700000000:R>")

-- Full jitter: every value in range, and not all identical.
local seen = {}
for _ = 1, 50 do
	local value = Util.backoff(3, 1, 60)
	h.check("backoff stays in range", value >= 0 and value <= 8)
	seen[tostring(math.floor(value * 1000))] = true
end
local distinct = 0
for _ in seen do
	distinct += 1
end
h.check("backoff is actually jittered", distinct > 10)

local hex = Util.randomHex(16)
h.check("randomHex gives the requested number of hex digits", #hex == 16 and string.match(hex, "^%x+$") ~= nil)
h.equals("randomHex handles lengths that are not a multiple of four", #Util.randomHex(7), 7)
h.check("randomHex varies", Util.randomHex(16) ~= Util.randomHex(16))

h.finish()
