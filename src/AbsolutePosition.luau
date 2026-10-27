--!strict

local Types = require(script.Parent.Types)
local BoxModel = require(script.Parent.BoxModel)
local Measurements = require(script.Parent.Measurements)
local LogicalProperties = require(script.Parent.LogicalProperties)
local SizingValue = require(script.Parent.SizingValue)
local PositionValues = require(script.Parent.PositionValues)
local AspectRatio = require(script.Parent.AspectRatio)

export type Context = {
	width: number,
	height: number,
	direction: string,
	lengths: Measurements.Context,
	minContentWidth: number?,
	maxContentWidth: number?,
	autoContentHeight: number?,
	-- Authoritative hypothetical margin-edge positions, not guessed origins.
	staticLeft: number?,
	staticRight: number?,
	staticTop: number?,
	replaced: boolean?,
}
export type Rect = {
	x: number,
	y: number,
	width: number,
	height: number,
	widthDefinite: boolean,
	heightDefinite: boolean,
}
type Axis = { position: number, size: number, definite: boolean }

local AbsolutePosition = {}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function word(style: Types.ComputedStyle, name: string, default: string): string?
	local tokens = style.properties[name]
	return if not tokens
		then default
		elseif #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value)
		else nil
end

local function axis(
	style: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	context: Context,
	horizontal: boolean
): (Axis?, string?)
	local sizeName = if horizontal then "width" else "height"
	local startName, endName = if horizontal then "left" else "top", if horizontal then "right" else "bottom"
	local basis = if horizontal then context.width else context.height
	local inset = if horizontal then metrics.horizontalInset else metrics.verticalInset
	local size, sizeFailure = SizingValue.resolve(style, sizeName, metrics, context.lengths, basis, inset)
	local minimum, minFailure = SizingValue.resolve(style, `min-{sizeName}`, metrics, context.lengths, basis, inset)
	local maximum, maxFailure = SizingValue.resolve(style, `max-{sizeName}`, metrics, context.lengths, basis, inset)
	local start, startFailure = PositionValues.inset(style, startName, basis, context.lengths)
	local finish, endFailure = PositionValues.inset(style, endName, basis, context.lengths)
	if sizeFailure or minFailure or maxFailure or startFailure or endFailure then
		return nil, sizeFailure or minFailure or maxFailure or startFailure or endFailure
	end
	local first, last = metrics.margin[startName], metrics.margin[endName]
	if not finite(first.value) or not finite(last.value) then
		return nil, "invalid-absolute-margin"
	end
	local firstMargin = if first.auto then 0 else first.value
	local lastMargin = if last.auto then 0 else last.value
	if start == nil and finish == nil then
		if horizontal and context.direction == "rtl" then
			finish = context.staticRight
		else
			start = if horizontal then context.staticLeft else context.staticTop
		end
		if start == nil and finish == nil then
			return nil, `absolute-static-position-provider-required:{sizeName}`
		end
		if (start ~= nil and not finite(start)) or (finish ~= nil and not finite(finish)) then
			return nil, "invalid-absolute-static-position"
		end
	end
	local definite = size ~= nil
	if size == nil then
		if context.replaced then
			return nil, "absolute-replaced-auto-size-provider-required"
		end
		if start ~= nil and finish ~= nil then
			size = math.max(0, basis - start - finish - inset - firstMargin - lastMargin)
			definite = true
		elseif horizontal then
			local minContent, maxContent = context.minContentWidth, context.maxContentWidth
			if minContent == nil or maxContent == nil then
				return nil, "absolute-shrink-to-fit-contributions-required"
			end
			if not finite(minContent) or not finite(maxContent) or minContent < 0 or maxContent < minContent then
				return nil, "invalid-absolute-intrinsic-widths"
			end
			local available = basis - (start or 0) - (finish or 0) - inset - firstMargin - lastMargin
			size = math.min(math.max(minContent, available), maxContent)
		else
			size = context.autoContentHeight
			if size == nil then
				return nil, "absolute-content-height-provider-required"
			end
			if not finite(size) or size < 0 then
				return nil, "invalid-absolute-content-height"
			end
		end
	end
	if size == nil then
		return nil, "absolute-size-provider-required"
	end
	local used = math.max(minimum or 0, math.min(size :: number, maximum or math.huge)) + inset
	local position: number
	if start ~= nil and finish ~= nil then
		local remaining = basis - start - finish - used - firstMargin - lastMargin
		if first.auto and last.auto then
			if not horizontal or remaining >= 0 then
				firstMargin, lastMargin = remaining / 2, remaining / 2
			elseif context.direction == "rtl" then
				firstMargin = remaining
			else
				lastMargin = remaining
			end
		elseif first.auto then
			firstMargin = remaining
		elseif last.auto then
			lastMargin = remaining
		elseif horizontal and context.direction == "rtl" then
			start = basis - finish - used - firstMargin - lastMargin
		end
		position = (start :: number) + firstMargin
	elseif start ~= nil then
		position = (start :: number) + firstMargin
	else
		position = basis - (finish :: number) - lastMargin - used
	end
	if not finite(position) or not finite(used) then
		return nil, "absolute-position-arithmetic-range-required"
	end
	return { position = position, size = used, definite = definite }, nil
end

-- The caller supplies the containing padding box, its direction, and metrics
-- whose percentage margins/padding were resolved against that box's width.
function AbsolutePosition.resolve(
	source: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	context: Context
): (Rect?, string?)
	if not finite(context.width) or not finite(context.height) or context.width < 0 or context.height < 0 then
		return nil, "definite-absolute-containing-block-required"
	end
	if context.direction ~= "ltr" and context.direction ~= "rtl" then
		return nil, "absolute-containing-direction-required"
	end
	local style, failure = LogicalProperties.view(source)
	if not style then
		return nil, failure
	end
	for _, name in { "position", "writing-mode" } do
		if style.unresolved[name] then
			return nil, style.unresolved[name]
		end
	end
	local position = word(style, "position", "static")
	if position ~= "absolute" and position ~= "fixed" then
		return nil, "absolute-position-required"
	end
	if word(style, "writing-mode", "horizontal-tb") ~= "horizontal-tb" then
		return nil, "vertical-absolute-position-provider-required"
	end
	if metrics.boxSizing ~= "content-box" and metrics.boxSizing ~= "border-box" then
		return nil, "invalid-absolute-box-sizing"
	end
	for _, value in { metrics.horizontalInset, metrics.verticalInset } do
		if not finite(value) or value < 0 then
			return nil, "invalid-absolute-insets"
		end
	end
	local ratio, ratioFailure = AspectRatio.resolve(style, metrics)
	if ratioFailure then
		return nil, ratioFailure
	end
	if ratio then
		local width, widthFailure =
			SizingValue.resolve(style, "width", metrics, context.lengths, context.width, metrics.horizontalInset)
		local height, heightFailure =
			SizingValue.resolve(style, "height", metrics, context.lengths, context.height, metrics.verticalInset)
		if widthFailure or heightFailure or width == nil or height == nil then
			return nil, widthFailure or heightFailure or "absolute-ratio-sizing-provider-required"
		end
	end
	local horizontal, horizontalFailure = axis(style, metrics, context, true)
	local vertical, verticalFailure = axis(style, metrics, context, false)
	if not horizontal or not vertical then
		return nil, horizontalFailure or verticalFailure
	end
	return {
		x = horizontal.position,
		y = vertical.position,
		width = horizontal.size,
		height = vertical.size,
		widthDefinite = horizontal.definite,
		heightDefinite = vertical.definite,
	},
		nil
end

return AbsolutePosition
