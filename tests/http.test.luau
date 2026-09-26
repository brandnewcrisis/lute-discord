--!strict
-- The bucket key rule. Getting this wrong only shows up under load, as
-- mysterious 429s, so it is pinned down here.
local Http = require("@discord/http")
local h = require("./harness")

local key = Http._routeKey

h.equals(
	"ids collapse but the major parameter stays",
	key("GET", "/channels/123456789012345678/messages/987654321098765432"),
	"GET /channels/:id/messages/:id:channels:123456789012345678"
)
h.check(
	"two channels are different buckets",
	key("POST", "/channels/111111111111111111/messages")
		~= key("POST", "/channels/222222222222222222/messages")
)
h.check(
	"two messages in one channel share a bucket",
	key("PATCH", "/channels/1/messages/111111111111111111")
		== key("PATCH", "/channels/1/messages/222222222222222222")
)
h.check(
	"method separates buckets",
	key("GET", "/channels/111111111111111111/messages")
		~= key("POST", "/channels/111111111111111111/messages")
)

-- Discord gives message deletion its own, much tighter bucket. Folding it in
-- with the other DELETEs makes a purge command 429 on the third message.
h.check(
	"message deletion is its own bucket",
	string.sub(key("DELETE", "/channels/111111111111111111/messages/222222222222222222"), 1, 14) == "DELETE_MESSAGE"
)
h.check(
	"other deletes are not",
	string.sub(key("DELETE", "/channels/111111111111111111"), 1, 14) ~= "DELETE_MESSAGE"
)

h.check(
	"reaction emoji do not become part of the key",
	key("PUT", "/channels/1/messages/111111111111111111/reactions/%F0%9F%94%A5/@me")
		== key("PUT", "/channels/1/messages/111111111111111111/reactions/%E2%9C%85/@me")
)
h.check(
	"guild is a major parameter too",
	key("GET", "/guilds/111111111111111111/members")
		~= key("GET", "/guilds/222222222222222222/members")
)
h.check(
	"non-major routes share regardless of id",
	key("GET", "/users/111111111111111111") == key("GET", "/users/222222222222222222")
)

h.finish()
