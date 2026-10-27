--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local NativeColors = require(script.Parent.NativeColors)
local NativeBox = require(script.Parent.NativeBox)

export type Context = {
	lengths: Measurements.Context,
	currentColor: Types.RgbaColor?,
	systemColors: { [string]: Types.RgbaColor }?,
}
export type Outline = { width: number, offset: number, color: NativeBox.Color }

local OutlinePaint = {}
local widths: { [string]: number } = { thin = 1, medium = 3, thick = 5 }
local currentColor: { Types.ValueToken } = { { kind = "word", value = "currentcolor" } }

local function word(tokens: { Types.ValueToken }?): string?
	return if tokens and #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

local function length(tokens: { Types.ValueToken }, context: Context): (number?, string?)
	local units = table.clone(context.lengths)
	units.allowRatio, units.percentageBasis, units.percentageDimension = nil, nil, nil
	local value, failure = Measurements.resolve(tokens, units)
	if not value then
		return nil, failure
	end
	if value.dimension == "number" and value.value == 0 then
		return 0, nil
	end
	if value.dimension ~= "length" or (value.percentage or 0) ~= 0 then
		return nil, "outline-requires-length-without-percentage"
	end
	return Measurements.toScalar(value, units), nil
end

function OutlinePaint.resolve(style: Types.ComputedStyle, context: Context): (Outline?, string?)
	local properties = style.properties
	local pattern = word(properties["outline-style"]) or (if not properties["outline-style"] then "none" else nil)
	if pattern == "none" then
		return nil, nil
	end
	if pattern ~= "solid" then
		return nil, `outline-style-backend-required:{pattern or "invalid"}`
	end
	local widthTokens = properties["outline-width"]
	local width: number? = widths[word(widthTokens) or (if not widthTokens then "medium" else "")]
	if not width and widthTokens then
		local failure: string?
		width, failure = length(widthTokens, context)
		if width == nil then
			return nil, failure or "invalid-outline-width"
		end
		if width < 0 and #widthTokens == 1 and widthTokens[1].kind == "function" then
			width = 0
		end
	end
	if width == nil or width < 0 then
		return nil, "invalid-outline-width"
	end
	local offset = 0
	if properties["outline-offset"] then
		local value, failure = length(properties["outline-offset"], context)
		if value == nil then
			return nil, failure or "invalid-outline-offset"
		end
		offset = value
	end
	local colorTokens = properties["outline-color"]
	if not colorTokens or word(colorTokens) == "auto" then
		colorTokens = currentColor
	end
	local color, failure = NativeColors.resolve(colorTokens, context)
	if not color then
		return nil, failure or "invalid-outline-color"
	end
	if width == 0 or color.transparency == 1 then
		return nil, nil
	end
	return { width = width, offset = offset, color = color }, nil
end

return OutlinePaint
