--!strict
local Components = require("@discord/components")
local Const = require("@discord/const")
local h = require("./harness")

local button = Components.button({ id = "a", label = "Click" })
h.equals("button type", button.type, Const.ComponentType.BUTTON)
h.equals("default style is primary", button.style, Const.ButtonStyle.PRIMARY)
h.equals("custom id", button.custom_id, "a")

local link = Components.linkButton("Docs", "https://example.com")
h.equals("link style", link.style, Const.ButtonStyle.LINK)
h.equals("link url", link.url, "https://example.com")
h.equals("link has no custom id", link.custom_id, nil)

h.equals("unicode emoji", h.some(Components.button({ id = "b", emoji = "\u{1f525}" }).emoji).name, "\u{1f525}")
h.equals("custom emoji id parses", h.some(Components.button({ id = "c", emoji = "blob:123" }).emoji).id, "123")

h.throws("button needs a label or emoji", "label, an emoji", function()
	Components.button({ id = "d" })
end)
h.throws("button needs an id", "needs an id", function()
	Components.button({ label = "x" })
end)
h.throws("long custom id", "limit is 100", function()
	Components.button({ id = string.rep("x", 101), label = "x" })
end)

local row = Components.row(button, link)
h.equals("row type", row.type, Const.ComponentType.ACTION_ROW)
h.equals("row children", #h.some(row.components), 2)
h.throws("row capacity", "at most 5", function()
	Components.row(button, button, button, button, button, button)
end)

local menu = Components.select({ id = "pick", options = { { label = "A", value = "a" } } })
h.equals("select type", menu.type, Const.ComponentType.STRING_SELECT)
h.throws("a select must be alone in its row", "alone in its row", function()
	Components.row(menu, button)
end)
h.throws("string select needs options", "needs options", function()
	Components.select({ id = "pick" })
end)
h.check("user select needs no options", Components.userSelect({ id = "u" }).type == Const.ComponentType.USER_SELECT)

-- Packing: buttons fill rows of five, a select breaks the run.
local packed = Components.rows({ button, button, button, button, button, button, menu })
h.equals("first row is full", #h.some(packed[1].components), 5)
h.equals("overflow starts a new row", #h.some(packed[2].components), 1)
h.equals("select gets its own row", h.some(packed[3].components)[1].type, Const.ComponentType.STRING_SELECT)

local modal = Components.modal({
	id = "form",
	title = "Feedback",
	inputs = { Components.textInput({ id = "body", label = "Say something", style = "paragraph" }) },
})
h.equals("modal wraps inputs in rows", h.some(modal.components)[1].type, Const.ComponentType.ACTION_ROW)
h.equals("paragraph style", h.some(h.some(modal.components)[1].components)[1].style, Const.TextInputStyle.PARAGRAPH)
h.throws("modal input count", "1 to 5", function()
	Components.modal({ id = "f", title = "t", inputs = {} })
end)

Components.setDisabled(packed, true)
h.check("setDisabled walks every row", h.some(packed[1].components)[1].disabled == true and h.some(packed[2].components)[1].disabled == true)

-- Errors name the bot's line however deep the helper that raised them, even
-- where the compiler has inlined the helper away.
h.throws("a long custom_id blames the caller", "components.test.luau", function()
	Components.button({ id = string.rep("x", 101), label = "x" })
end)
h.throws("a bad section accessory blames the caller", "components.test.luau", function()
	Components.section({ accessory = Components.text("x") }, "a")
end)

h.finish()
