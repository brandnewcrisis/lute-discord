--!strict
--[[
	/roll, /choose, /8ball and /poll.

	/poll is the interesting one: a live message whose buttons mutate shared
	state and re-render in place. It shows the whole component loop --
	building ids that carry state, routing them by prefix, updating the
	source message, and locking the thing down when it ends.
]]
local Discord = require("@discord")
local Commands = Discord.Commands
local Components = Discord.Components
local Embed = Discord.Embed
local Util = Discord.Util

local Ctx = require("@bot/ctx")

local Fun = {}

local ANSWERS = {
	"It is certain.",
	"Without a doubt.",
	"You may rely on it.",
	"Ask again later.",
	"Better not tell you now.",
	"Do not count on it.",
	"My reply is no.",
	"Very doubtful.",
	"Signs point to yes.",
	"Reply hazy, try again.",
}

local LETTERS = { "\u{1f1e6}", "\u{1f1e7}", "\u{1f1e8}", "\u{1f1e9}", "\u{1f1ea}" }

type Poll = {
	question: string,
	options: { string },
	--- userId -> option index. One vote each, and changing it moves the vote
	--- rather than adding a second.
	votes: { [string]: number },
	authorId: string,
	closed: boolean,
}

local polls: { [string]: Poll } = {}

Fun.commands = {
	Commands.slash("roll", "Roll dice in NdM+K notation")
		:stringOption("dice", "For example 2d6+3", { required = true }),
	Commands.slash("choose", "Pick one of several options")
		:stringOption("options", "Comma separated", { required = true }),
	Commands.slash("8ball", "Consult the ball"):stringOption("question", "What do you want to know", { required = true }),
	Commands.slash("poll", "Start a poll with up to five options")
		:stringOption("question", "What are you asking", { required = true })
		:stringOption("options", "Comma separated, 2 to 5", { required = true }),
}

--[[
	Parses `NdM+K`.

	Bounded deliberately: `999d999` is 999 rolls and a message longer than
	Discord accepts, so the limits are part of the parse rather than a
	failure at send time.
]]
local function parseDice(text: string): (number?, number?, number, string?)
	local count, sides, modifier = string.match(string.lower(text), "^%s*(%d*)d(%d+)%s*([%+%-]?%d*)%s*$")
	if sides == nil then
		return nil, nil, 0, "Use NdM notation, for example `2d6` or `1d20+5`."
	end
	local rolls = tonumber(count) or 1
	local faces = tonumber(sides) :: number
	if rolls < 1 or rolls > 25 then
		return nil, nil, 0, "Roll between 1 and 25 dice."
	end
	if faces < 2 or faces > 1000 then
		return nil, nil, 0, "Dice need between 2 and 1000 faces."
	end
	return rolls, faces, tonumber(modifier) or 0, nil
end

local function renderPoll(id: string): any
	local poll = polls[id]
	local tally = table.create(#poll.options, 0)
	local total = 0
	for _, choice in poll.votes do
		tally[choice] = (tally[choice] or 0) + 1
		total += 1
	end

	local lines = {}
	for index, option in poll.options do
		local count = tally[index] or 0
		local share = if total > 0 then count / total else 0
		-- A twenty-cell bar reads better than a percentage alone and costs
		-- nothing; Discord has no progress element.
		local filled = math.floor(share * 20 + 0.5)
		table.insert(
			lines,
			`{LETTERS[index]} **{option}**\n`
				.. `\`{string.rep("\u{2588}", filled)}{string.rep("\u{2591}", 20 - filled)}\` `
				.. `{count} ({math.floor(share * 100 + 0.5)}%)`
		)
	end

	local embed = Embed.new()
		:setTitle(poll.question)
		:setDescription(table.concat(lines, "\n\n"))
		:setColor(if poll.closed then Discord.Color.GREY else Discord.Color.BLURPLE)
		:setFooter(
			if poll.closed
				then `Final result - {total} vote(s)`
				else `{total} vote(s) - one each, change it any time`
		)

	local buttons = {}
	for index, option in poll.options do
		table.insert(
			buttons,
			Components.button({
				id = `poll:{id}:{index}`,
				label = Util.truncate(option, 20),
				emoji = LETTERS[index],
				style = "secondary",
				disabled = poll.closed,
			})
		)
	end
	if not poll.closed then
		table.insert(
			buttons,
			Components.button({ id = `poll:{id}:close`, label = "End poll", style = "danger" })
		)
	end

	return { embeds = { embed }, components = Components.rows(buttons) }
end

function Fun.register(client: Discord.Client, _ctx: Ctx.Ctx)
	client:command("roll", function(ix: Discord.Interaction)
		local rolls, faces, modifier, err = parseDice(ix:opt("dice"))
		if rolls == nil then
			ix:replyEphemeral(err :: string)
			return
		end

		local results = {}
		local total = modifier
		for _ = 1, rolls do
			local value = math.random(1, faces :: number)
			total += value
			table.insert(results, tostring(value))
		end

		local detail = table.concat(results, " + ")
		if modifier ~= 0 then
			detail ..= ` {if modifier > 0 then "+" else "-"} {math.abs(modifier)}`
		end
		ix:reply({
			embeds = {
				Embed.new()
					:setTitle(`\u{1f3b2} {total}`)
					:setDescription(if rolls > 1 or modifier ~= 0 then `\`{detail}\`` else "\u{200b}")
					:setColor(Discord.Color.GREEN)
					:setFooter(`{rolls}d{faces}{if modifier ~= 0 then (if modifier > 0 then "+" else "") .. modifier else ""}`),
			},
		})
	end)

	client:command("choose", function(ix: Discord.Interaction)
		local options: { string } = {}
		for part in string.gmatch(ix:opt("options"), "[^,]+") do
			local trimmed = string.match(part, "^%s*(.-)%s*$") :: string
			if trimmed ~= "" then
				table.insert(options, trimmed)
			end
		end
		if #options < 2 then
			ix:replyEphemeral("Give me at least two comma-separated options.")
			return
		end
		-- Echoing user text: escape it, and forbid mentions, or `/choose
		-- @everyone` becomes a ping.
		ix:reply({
			content = `I pick **{Util.escapeMarkdown(options[math.random(1, #options)])}**`,
			allowed_mentions = Discord.Payload.NO_MENTIONS,
		})
	end)

	client:command("8ball", function(ix: Discord.Interaction)
		ix:reply({
			embeds = {
				Embed.new()
					:setAuthor(Util.truncate(ix:opt("question"), 200))
					:setDescription(`\u{1f3b1} {ANSWERS[math.random(1, #ANSWERS)]}`)
					:setColor(Discord.Color.DARK),
			},
			allowed_mentions = Discord.Payload.NO_MENTIONS,
		})
	end)

	client:command("poll", function(ix: Discord.Interaction)
		local options: { string } = {}
		for part in string.gmatch(ix:opt("options"), "[^,]+") do
			local trimmed = string.match(part, "^%s*(.-)%s*$") :: string
			if trimmed ~= "" and #options < 5 then
				table.insert(options, Util.escapeMarkdown(trimmed))
			end
		end
		if #options < 2 then
			ix:replyEphemeral("A poll needs two to five comma-separated options.")
			return
		end

		-- The interaction id is unique and already in hand, so it makes a
		-- good key without a counter or a random.
		local id = ix.id
		polls[id] = {
			question = Util.escapeMarkdown(ix:opt("question")),
			options = options,
			votes = {},
			authorId = ix.user.id,
			closed = false,
		}
		ix:reply(renderPoll(id))
	end)

	--[[
		One handler for every poll button, of every poll, forever.

		The state lives in the custom id (`poll:<pollId>:<choice>`), which is
		what makes this survive any number of concurrent polls without a
		collector per message. It does NOT survive a restart -- `polls` is in
		memory -- and the handler says so rather than silently doing nothing.
	]]
	client:component("poll:", function(ix: Discord.Interaction)
		local pollId, action = string.match(ix.data.custom_id or "", "^poll:([^:]+):(.+)$")
		local poll = if pollId ~= nil then polls[pollId] else nil
		if poll == nil then
			ix:replyEphemeral("That poll is from before my last restart, so I no longer have its votes.")
			return
		end

		if action == "close" then
			if ix.user.id ~= poll.authorId then
				ix:replyEphemeral("Only whoever started the poll can end it.")
				return
			end
			poll.closed = true
			ix:update(renderPoll(pollId :: string))
			return
		end

		local choice = tonumber(action)
		if choice == nil or poll.options[choice] == nil then
			ix:deferUpdate()
			return
		end
		if poll.votes[ix.user.id] == choice then
			poll.votes[ix.user.id] = nil
		else
			poll.votes[ix.user.id] = choice
		end
		ix:update(renderPoll(pollId :: string))
	end)
end

return Fun
