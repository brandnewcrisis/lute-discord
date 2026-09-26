--!strict
--[[
	Colour inputs, resolved in one place.

	Embeds and Components V2 containers both take an RGB integer, and a
	caller should be able to hand either one the same thing: a number, a
	`Const.Color` entry, or a `#rrggbb` string. Two parsers would drift --
	one would learn `#fff` and the other would not -- so both go through
	here.
]]
local Color = {}

export type ColorInput = number | string

--[[
	The RGB integer for `value`, or nil when it is not a colour.

	Nil rather than an error so each caller can phrase its own: an embed
	colour and a container accent both raise, but name different options. `#rgb` shorthand expands the way CSS does (`#fff` is white),
	which is what anyone typing it means.
]]
function Color.resolve(value: ColorInput): number?
	if type(value) == "string" then
		local hex = string.gsub(value, "^#", "")
		if string.match(hex, "^%x%x%x$") then
			local r, g, b = string.sub(hex, 1, 1), string.sub(hex, 2, 2), string.sub(hex, 3, 3)
			hex = r .. r .. g .. g .. b .. b
		end
		if not string.match(hex, "^%x%x%x%x%x%x$") then
			return nil
		end
		return tonumber(hex, 16)
	end
	if value ~= math.floor(value) or value < 0 or value > 0xFFFFFF then
		return nil
	end
	return value
end

return Color
