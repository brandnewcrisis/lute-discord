--!strict
local Http = require("@discord/http")
local Json = require("@discord/json")
local Webhook = require("@discord/webhook")
local h = require("./harness")

local id, token = Webhook.parseUrl("https://discord.com/api/webhooks/123456789012345678/abc-DEF_ghi")
h.equals("id from a plain URL", id, "123456789012345678")
h.equals("token keeps dashes and underscores", token, "abc-DEF_ghi")

local vid, vtoken = Webhook.parseUrl("https://canary.discordapp.com/api/v10/webhooks/42/tok?wait=true")
h.equals("versioned canary URL", vid, "42")
h.equals("query string is not part of the token", vtoken, "tok")

h.throws("a non-webhook URL is refused", "not a webhook URL", function()
	Webhook.parseUrl("https://discord.com/channels/1/2")
end)

type Call = { method: string, url: string, headers: { [string]: string }, body: string? }
local calls: { Call } = {}
local function transport(url: string, request: Http.TransportRequest): Http.TransportResponse
	table.insert(calls, { method = request.method, url = url, headers = request.headers, body = request.body })
	if request.method == "DELETE" then
		return { status = 204, headers = {}, body = "" }
	end
	return { status = 200, headers = {}, body = Json.encode({ id = "999", content = "hi", channel_id = "1" }) }
end

local hook = Webhook.fromUrl("https://discord.com/api/webhooks/42/tok", {
	threadId = "77",
	http = { transport = transport },
})

local sent = hook:send("hi")
h.equals("send returns the message", sent.id, "999")
local call = calls[1]
h.equals("send posts to the token route", call.method, "POST")
h.check("send waits for the message", string.find(call.url, "wait=true", 1, true) ~= nil)
h.check("send targets the thread", string.find(call.url, "thread_id=77", 1, true) ~= nil)
h.check("send keeps components", string.find(call.url, "with_components=true", 1, true) ~= nil)
h.check("no Authorization header on a token route", call.headers.Authorization == nil)

hook:edit("999", { content = "edited" })
h.equals("edit patches the message", calls[2].method, "PATCH")
h.check("edit path names the message", string.find(calls[2].url, "/webhooks/42/tok/messages/999", 1, true) ~= nil)

hook:delete("999")
h.equals("delete removes the message", calls[3].method, "DELETE")
h.check("delete keeps the thread", string.find(calls[3].url, "thread_id=77", 1, true) ~= nil)

h.finish()
