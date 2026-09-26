--!strict
--[[
	The error value every REST call throws on failure.

	Errors are thrown rather than returned because a bot has exactly one place
	that can sensibly handle "Discord said no" -- the per-event handler -- and
	threading `(ok, err)` back through every call site to reach it makes the
	happy path unreadable. The client wraps each handler in `xpcall`, so a
	throw costs one failed command, never the process.

	`__tostring` matters for logs, but note that Lute's top level prints
	NOTHING for an uncaught table error -- only the stack trace. A script
	calling the API outside any handler should wrap its body in
	`Discord.main`, which prints the message; `Client.deploy`, `login` and
	`run` already raise plain text for the same reason.
]]

local ApiError = {}
ApiError.__index = ApiError

export type ApiError = typeof(setmetatable(
	{} :: {
		kind: "discord",
		status: number,
		code: number,
		message: string,
		errors: any?,
		method: string,
		path: string,
		retryAfter: number?,
	},
	{} :: typeof(ApiError)
))

--[[
	Flattens Discord's nested field-error object into readable lines.

	The shape is recursive: `{"embeds":{"0":{"description":{"_errors":[...]}}}}`
	The useful part is the path plus the message, and without flattening it
	the only thing a log line shows is that something, somewhere, was invalid.
]]
local function collect(node: any, path: string, out: { string })
	if type(node) ~= "table" then
		return
	end
	if type(node._errors) == "table" then
		for _, entry in node._errors do
			if type(entry) == "table" and entry.message then
				table.insert(out, `{path}: {entry.message}`)
			end
		end
		return
	end
	for key, child in node do
		local childPath = if path == "" then tostring(key) else `{path}.{key}`
		collect(child, childPath, out)
	end
end

function ApiError.fieldErrors(self: ApiError): { string }
	local out = {}
	collect(self.errors, "", out)
	return out
end

function ApiError.__tostring(self: ApiError): string
	local text = `Discord {self.status} ({self.code}) on {self.method} {self.path}: {self.message}`
	local fields = ApiError.fieldErrors(self)
	if #fields > 0 then
		text ..= "\n  " .. table.concat(fields, "\n  ")
	end
	return text
end

function ApiError.new(status: number, method: string, path: string, body: any): ApiError
	local payload = if type(body) == "table" then body else {}
	return setmetatable({
		kind = "discord" :: "discord",
		status = status,
		code = tonumber(payload.code) or 0,
		message = tostring(payload.message or `HTTP {status}`),
		errors = payload.errors,
		method = method,
		path = path,
		retryAfter = tonumber(payload.retry_after),
	}, ApiError)
end

--- True for the value thrown by a failed REST call. Use it to tell a Discord
--- rejection apart from a bug in your own handler.
function ApiError.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == ApiError
end

--- True when the error is Discord saying "that does not exist", which is
--- usually a race (message deleted mid-edit) rather than a fault.
function ApiError.isUnknownResource(value: any): boolean
	return ApiError.is(value) and (value :: ApiError).status == 404
end

--- True when the bot lacks the permission for what it just tried.
function ApiError.isForbidden(value: any): boolean
	return ApiError.is(value) and (value :: ApiError).status == 403
end

return ApiError
