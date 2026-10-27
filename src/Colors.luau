--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local ColorSpaces = require(script.Parent.ColorSpaces)
local ColorFunctions = require(script.Parent.ColorFunctions)
local RelativeColors = require(script.Parent.RelativeColors)

type Color = Types.RgbaColor
type Token = Types.ValueToken

export type Context = { currentColor: Color?, systemColors: { [string]: Color }? }

local Colors = {}
local colorFunctions = {
	rgb = true,
	rgba = true,
	hsl = true,
	hsla = true,
	hwb = true,
	lab = true,
	lch = true,
	oklab = true,
	oklch = true,
	color = true,
	["color-mix"] = true,
	["light-dark"] = true,
}

-- Syntactic family only: resolving its arguments/profile remains a separate
-- operation. Shorthands use this even when a grammar library lags relative CSS.
function Colors.isColorFunction(name: string): boolean
	return colorFunctions[string.lower(name)] == true
end
local resolve: ({ Token }, Context) -> (Color?, string?)

local function significant(tokens: { Token }): { Token }
	local result = {}
	for _, token in tokens do
		if token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(result, token)
		end
	end
	return result
end

local function percentage(token: Token): (number?, string?)
	local value, failure = Measurements.resolve({ token }, {})
	if not value then
		return nil, failure
	end
	if value.dimension ~= "percentage" or value.value < 0 or value.value > 1 then
		return nil, "invalid-mix-percentage"
	end
	return value.value, nil
end

local function argument(tokens: { Token }, context: Context): (Color?, number?, string?)
	local parts = significant(tokens)
	if #parts == 1 then
		local color, failure = resolve(parts, context)
		return color, nil, failure
	end
	if #parts ~= 2 then
		return nil, nil, "invalid-color-mix-argument"
	end
	local functionName = string.lower(parts[1].value)
	local weightIndex = if parts[1].kind == "percentage"
			or (
				parts[1].kind == "function"
				and (
					functionName == "calc"
					or functionName == "min"
					or functionName == "max"
					or functionName == "clamp"
				)
			)
		then 1
		else 2
	local weight, failure = percentage(parts[weightIndex])
	if not weight then
		return nil, nil, failure
	end
	local color, colorFailure = resolve({ parts[3 - weightIndex] }, context)
	return color, weight, colorFailure
end

local function mix(token: Token, context: Context): (Color?, string?)
	local groups: { { Token } } = { {} }
	for _, child in token.children or {} do
		if child.kind == "div" and child.value == "," then
			table.insert(groups, {} :: { Token })
		else
			table.insert(groups[#groups], child)
		end
	end
	if #groups ~= 3 then
		return nil, "invalid-color-mix-groups"
	end
	local header = significant(groups[1])
	if
		#header ~= 2
		or header[1].kind ~= "word"
		or string.lower(header[1].value) ~= "in"
		or header[2].kind ~= "word"
	then
		return nil, "unsupported-color-mix-interpolation"
	end
	local space = string.lower(header[2].value)
	if space ~= "srgb" and space ~= "srgb-linear" and space ~= "oklab" and space ~= "lab" then
		return nil, `unsupported-mix-space:{space}`
	end
	local a, wa, aFailure = argument(groups[2], context)
	local b, wb, bFailure = argument(groups[3], context)
	if not a or not b then
		return nil, aFailure or bFailure
	end
	if wa == nil and wb == nil then
		wa = 0.5
		wb = 0.5
	elseif wa == nil then
		wa = 1 - (wb :: number)
	elseif wb == nil then
		wb = 1 - wa
	end
	local total = (wa :: number) + (wb :: number)
	if total == 0 then
		return nil, "zero-color-mix-weight"
	end
	local alphaScale = math.min(total, 1)
	local leftWeight = (wa :: number) / total
	local rightWeight = (wb :: number) / total
	local alpha = a.alpha * leftWeight + b.alpha * rightWeight
	if alpha == 0 then
		return { r = 0, g = 0, b = 0, alpha = 0 }, nil
	end
	local ar, ag, ab = a.r, a.g, a.b
	local br, bg, bb = b.r, b.g, b.b
	if space == "oklab" then
		ar, ag, ab = ColorSpaces.toOklab(ar, ag, ab)
		br, bg, bb = ColorSpaces.toOklab(br, bg, bb)
	elseif space == "lab" then
		ar, ag, ab = ColorSpaces.toLab(ar, ag, ab)
		br, bg, bb = ColorSpaces.toLab(br, bg, bb)
	elseif space == "srgb-linear" then
		ar, ag, ab = ColorSpaces.toLinear(ar, ag, ab)
		br, bg, bb = ColorSpaces.toLinear(br, bg, bb)
	end
	local function channel(x: number, y: number): number
		return (x * a.alpha * leftWeight + y * b.alpha * rightWeight) / alpha
	end
	local r, g, blue = channel(ar, br), channel(ag, bg), channel(ab, bb)
	if space == "oklab" then
		r, g, blue = ColorSpaces.fromOklab(r, g, blue)
	elseif space == "lab" then
		r, g, blue = ColorSpaces.fromLab(r, g, blue)
	elseif space == "srgb-linear" then
		r, g, blue = ColorSpaces.fromLinear(r, g, blue)
	end
	return { r = r, g = g, b = blue, alpha = alpha * alphaScale }, nil
end

resolve = function(tokens: { Token }, context: Context): (Color?, string?)
	local parts = significant(tokens)
	if #parts ~= 1 then
		return nil, "expected-single-color"
	end
	local token = parts[1]
	if token.color then
		return token.color, nil
	end
	if token.kind == "word" and string.lower(token.value) == "currentcolor" then
		return context.currentColor, if context.currentColor then nil else "current-color-required"
	end
	if token.kind == "word" and context.systemColors then
		local system = context.systemColors[string.lower(token.value)]
		if system then
			return system, nil
		end
	end
	if token.kind == "function" and string.lower(token.value) == "color-mix" then
		return mix(token, context)
	end
	if token.kind == "function" then
		local relative, failure, handled = RelativeColors.resolve(token, function(base)
			return resolve({ base }, context)
		end)
		if handled then
			return relative, failure
		end
		return ColorFunctions.resolve(token)
	end
	return nil, `unsupported-color:{token.kind}:{token.value}`
end

Colors.resolve = resolve
return Colors
