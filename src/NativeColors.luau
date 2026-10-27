--!strict

local Types = require(script.Parent.Types)
local Colors = require(script.Parent.Colors)
local GamutMapping = require(script.Parent.GamutMapping)

export type Color = { value: Color3, transparency: number }
local NativeColors = {}

function NativeColors.fromRgba(value: Types.RgbaColor): (Color?, string?)
	local mapped, failure = GamutMapping.srgb(value)
	if not mapped then
		return nil, failure
	end
	return { value = Color3.new(mapped.r, mapped.g, mapped.b), transparency = 1 - mapped.alpha }, nil
end

function NativeColors.resolve(tokens: { Types.ValueToken }, context: Colors.Context): (Color?, string?)
	local value, failure = Colors.resolve(tokens, context)
	if not value then
		return nil, failure
	end
	return NativeColors.fromRgba(value)
end

return NativeColors
