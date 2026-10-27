--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local Colors = require(script.Parent.Colors)
local NativeColors = require(script.Parent.NativeColors)
type Token = Types.ValueToken

export type Context = {
	lengths: Measurements.Context,
	currentColor: Types.RgbaColor?,
	systemColors: { [string]: Types.RgbaColor }?,
}
export type Shadow = { x: number, y: number, blur: number, spread: number, inset: boolean, color: Types.RgbaColor }
export type Ring = { width: number, color: NativeColors.Color }
export type Rect = { x: number, y: number, width: number, height: number, color: NativeColors.Color }

local ShadowPaint = {}
local mathFunctions = { calc = true, min = true, max = true, clamp = true }

local function length(token: Token, context: Context): (number?, string?)
	local units = table.clone(context.lengths)
	units.percentageBasis, units.percentageDimension, units.allowRatio = nil, nil, nil
	units.strictPercentageTypes, units.allowLengthPercentage = true, false
	local value, failure = Measurements.resolve({ token }, units)
	if not value then
		return nil, failure or "invalid-shadow-length"
	elseif token.kind == "number" and value.value == 0 then
		return 0, nil
	elseif value.dimension ~= "length" or value.percentage ~= nil then
		return nil, "shadow-requires-length-without-percentage"
	end
	return value.value, nil
end

local function layer(tokens: { Token }, context: Context): (Shadow?, string?)
	local lengths: { Token } = {}
	local inset = false
	local color: Types.RgbaColor? = nil
	local endedLengths = false
	for _, token in tokens do
		if token.kind == "word" and string.lower(token.value) == "inset" then
			if inset then
				return nil, "duplicate-shadow-inset"
			end
			inset = true
			endedLengths = #lengths > 0
		elseif
			token.kind == "number"
			or token.kind == "dimension"
			or token.kind == "percentage"
			or token.kind == "function" and mathFunctions[string.lower(token.value)]
		then
			if endedLengths then
				return nil, "shadow-lengths-must-be-contiguous"
			end
			table.insert(lengths, token)
		else
			if color then
				return nil, "duplicate-shadow-color"
			end
			local failure: string?
			color, failure = Colors.resolve({ token }, context)
			if not color then
				return nil, failure or "unsupported-shadow-color"
			end
			endedLengths = #lengths > 0
		end
	end
	if #lengths < 2 or #lengths > 4 then
		return nil, "shadow-requires-two-to-four-lengths"
	end
	local values = { 0, 0, 0, 0 }
	for index, token in lengths do
		local value, failure = length(token, context)
		if value == nil then
			return nil, failure
		end
		if index == 3 and value < 0 then
			if token.kind ~= "function" then
				return nil, "negative-shadow-blur"
			end
			value = 0
		end
		values[index] = value
	end
	if not color then
		local failure: string?
		color, failure = Colors.resolve({ { kind = "word", value = "currentcolor" } }, context)
		if not color then
			return nil, failure or "shadow-current-color-required"
		end
	end
	local resolvedColor = color
	if not resolvedColor then
		return nil, "shadow-current-color-required"
	end
	return { x = values[1], y = values[2], blur = values[3], spread = values[4], inset = inset, color = resolvedColor },
		nil
end

function ShadowPaint.resolve(tokens: { Token }, context: Context): ({ Shadow }?, string?)
	local groups: { { Token } } = { {} }
	for _, token in tokens do
		if token.kind == "space" or token.kind == "comment" then
			continue
		elseif token.kind == "div" and token.value == "," then
			table.insert(groups, {} :: { Token })
		else
			table.insert(groups[#groups], token)
		end
	end
	if
		#groups == 1
		and #groups[1] == 1
		and groups[1][1].kind == "word"
		and string.lower(groups[1][1].value) == "none"
	then
		return {}, nil
	end
	local result: { Shadow } = {}
	for index, tokensInLayer in groups do
		local value, failure = layer(tokensInLayer, context)
		if not value then
			return nil, `shadow-layer-{index}:{failure or "invalid"}`
		end
		table.insert(result, value)
	end
	return result, nil
end

-- Preserve all-or-nothing paint: an unsupported visible layer cannot be dropped
-- while rendering only the remaining rings. CSS's first shadow is topmost.
function ShadowPaint.rings(shadows: { Shadow }): ({ Ring }?, string?)
	local result: { Ring } = {}
	for index, shadow in shadows do
		if shadow.color.alpha == 0 then
			continue
		elseif shadow.inset then
			return nil, `inset-shadow-backend-required:{index}`
		elseif shadow.blur ~= 0 then
			return nil, `blurred-shadow-backend-required:{index}`
		elseif shadow.x ~= 0 or shadow.y ~= 0 then
			return nil, `offset-shadow-backend-required:{index}`
		elseif shadow.spread > 0 then
			local color, failure = NativeColors.fromRgba(shadow.color)
			if not color then
				return nil, failure
			end
			table.insert(result, { width = shadow.spread, color = color })
		end
	end
	return result, nil
end

-- Rectangle knockout shared by sharp inner and outer shadows. Each layer
-- uses disjoint bands; overlapping layers still composite in source order.
local function subtract(
	result: { Rect },
	color: NativeColors.Color,
	x: number,
	y: number,
	width: number,
	height: number,
	left: number,
	top: number,
	right: number,
	bottom: number
)
	local function add(rx: number, ry: number, rw: number, rh: number)
		if rw > 0 and rh > 0 then
			table.insert(result, { x = rx, y = ry, width = rw, height = rh, color = color })
		end
	end
	if right <= left or bottom <= top then
		add(x, y, width, height)
		return
	end
	local clippedLeft = math.clamp(left, x, x + width)
	local clippedRight = math.clamp(right, x, x + width)
	local clippedTop = math.clamp(top, y, y + height)
	local clippedBottom = math.clamp(bottom, y, y + height)
	add(x, y, width, clippedTop - y)
	add(x, clippedBottom, width, y + height - clippedBottom)
	add(x, clippedTop, clippedLeft - x, clippedBottom - clippedTop)
	add(clippedRight, clippedTop, x + width - clippedRight, clippedBottom - clippedTop)
end

-- Square padding-edge knockout. Return bottommost rectangles first; each
-- layer uses disjoint bands so translucent corners are painted exactly once.
function ShadowPaint.insetRects(
	shadows: { Shadow },
	x: number,
	y: number,
	width: number,
	height: number,
	rounded: boolean
): ({ Rect }?, string?)
	local result: { Rect } = {}
	for _, value in { x, y, width, height, x + width, y + height } do
		if value ~= value or value < 0 or math.abs(value) == math.huge then
			return nil, "invalid-inset-shadow-padding-box"
		end
	end
	for index = #shadows, 1, -1 do
		local shadow = shadows[index]
		if not shadow.inset or shadow.color.alpha == 0 then
			continue
		elseif shadow.blur ~= 0 then
			return nil, `blurred-inset-shadow-backend-required:{index}`
		elseif rounded then
			return nil, `rounded-inset-shadow-backend-required:{index}`
		end
		local left = x + shadow.x + shadow.spread
		local top = y + shadow.y + shadow.spread
		local right = x + width + shadow.x - shadow.spread
		local bottom = y + height + shadow.y - shadow.spread
		for _, edge in { left, top, right, bottom } do
			if edge ~= edge or math.abs(edge) == math.huge then
				return nil, "inset-shadow-geometry-range-required"
			end
		end
		local color, failure = NativeColors.fromRgba(shadow.color)
		if not color then
			return nil, failure
		end
		subtract(result, color, x, y, width, height, left, top, right, bottom)
	end
	return result, nil
end

function ShadowPaint.outerRects(
	shadows: { Shadow },
	width: number,
	height: number,
	rounded: boolean
): ({ Rect }?, string?)
	local result: { Rect } = {}
	if width < 0 or height < 0 or width ~= width or height ~= height or math.max(width, height) == math.huge then
		return nil, "invalid-outer-shadow-border-box"
	end
	for index = #shadows, 1, -1 do
		local shadow = shadows[index]
		if shadow.inset or shadow.color.alpha == 0 then
			continue
		elseif shadow.blur ~= 0 then
			return nil, `blurred-shadow-backend-required:{index}`
		elseif rounded then
			return nil, `rounded-offset-shadow-backend-required:{index}`
		end
		local left = shadow.x - shadow.spread
		local top = shadow.y - shadow.spread
		local right = width + shadow.x + shadow.spread
		local bottom = height + shadow.y + shadow.spread
		for _, edge in { left, top, right, bottom, right - left, bottom - top } do
			if edge ~= edge or math.abs(edge) == math.huge then
				return nil, "outer-shadow-geometry-range-required"
			end
		end
		if right <= left or bottom <= top then
			continue
		end
		local color, failure = NativeColors.fromRgba(shadow.color)
		if not color then
			return nil, failure
		end
		subtract(result, color, left, top, right - left, bottom - top, 0, 0, width, height)
	end
	return result, nil
end

return ShadowPaint
