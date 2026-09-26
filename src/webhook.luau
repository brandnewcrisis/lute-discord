--!strict
--[[
	A webhook, driven from its URL alone.

		local hook = Discord.Webhook.fromUrl(env:require("ALERT_WEBHOOK"))
		hook:send({ content = "Deploy finished", username = "CI" })

	No bot token, no gateway, no application. The token in a webhook URL is
	the whole credential, which makes this the right tool for a cron job, a
	CI step or an alerting script that only ever posts. It is also why a
	webhook URL deserves the same care as a bot token: anyone holding it can
	post as the webhook, and delete what it posted.

	Messages are sent with `wait = true`, so `send` returns the created
	message and its id -- which is what `edit` and `delete` need later.
	Discord's default is fire-and-forget with a 204, which saves nothing
	worth having and loses the id.
]]
local Api = require("@discord/api")
local Http = require("@discord/http")
local Types = require("@discord/types")

local Webhook = {}
Webhook.__index = Webhook

export type Options = {
	--- Post into this thread (required for forum and media channels unless
	--- the payload sets `thread_name` to start a new post).
	threadId: string?,
	--- Transport overrides, as for `Http.new`. Mostly for tests.
	http: Http.HttpOptions?,
}

export type Webhook = typeof(setmetatable(
	{} :: {
		id: string,
		token: string,
		threadId: string?,
		api: Api.Api,
	},
	{} :: typeof(Webhook)
))

--[[
	Splits a webhook URL into its id and token.

	Accepts every host Discord has handed these out on -- `discord.com`,
	`discordapp.com`, and the `canary.` and `ptb.` subdomains -- with or
	without an `/api/v10` segment, because people paste whichever one their
	client showed them.
]]
function Webhook.parseUrl(url: string): (string, string)
	local id, token = string.match(url, "/webhooks/(%d+)/([%w_%-]+)")
	if id == nil or token == nil then
		error("not a webhook URL: expected https://discord.com/api/webhooks/<id>/<token>", 2)
	end
	return id, token
end

function Webhook.new(id: string, token: string, options: Options?): Webhook
	local opts: Options = options or {}
	-- The token routes are unauthenticated, so the Http client carries no
	-- bot token at all -- there is nothing to leak if this object is logged.
	local http = Http.new("", opts.http)
	return setmetatable({
		id = id,
		token = token,
		threadId = opts.threadId,
		api = Api.new(http),
	}, Webhook)
end

function Webhook.fromUrl(url: string, options: Options?): Webhook
	local id, token = Webhook.parseUrl(url)
	return Webhook.new(id, token, options)
end

--[[
	Posts a message and returns it.

	Beyond the usual payload fields, a webhook message may set `username`
	and `avatar_url` to override the webhook's own name and picture for this
	one message. `with_components` is always sent, because a webhook not
	owned by an application otherwise drops its components without a word.
]]
function Webhook.send(self: Webhook, payload: Types.MessageInput): Types.Message
	local message = self.api.webhooks.execute(self.id, self.token, payload, {
		wait = true,
		thread_id = self.threadId,
		with_components = true,
	})
	-- `wait = true` guarantees a body; a nil here means Discord changed.
	return assert(message, "Discord returned no message despite wait=true")
end

function Webhook.edit(self: Webhook, messageId: string, payload: Types.MessageInput): Types.Message
	return self.api.webhooks.editMessage(self.id, self.token, messageId, payload, {
		thread_id = self.threadId,
		with_components = true,
	})
end

function Webhook.delete(self: Webhook, messageId: string)
	self.api.webhooks.deleteMessage(self.id, self.token, messageId, self.threadId)
end

function Webhook.fetchMessage(self: Webhook, messageId: string): Types.Message
	return self.api.webhooks.getMessage(self.id, self.token, messageId, self.threadId)
end

--- The webhook's own record: name, channel, avatar.
function Webhook.info(self: Webhook): Types.Webhook
	return self.api.webhooks.getWithToken(self.id, self.token)
end

--- Renames it, or changes its default avatar (a `data:` URI; see
--- `Util.dataUri`). Moving it to another channel needs a bot token.
function Webhook.modify(self: Webhook, patch: Types.WebhookPatch): Types.Webhook
	return self.api.webhooks.editWithToken(self.id, self.token, patch)
end

--- Deletes the webhook itself. The URL stops working for everyone.
function Webhook.destroy(self: Webhook)
	self.api.webhooks.deleteWithToken(self.id, self.token)
end

return Webhook
