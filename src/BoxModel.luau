--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local LogicalProperties = require(script.Parent.LogicalProperties)

export type Context = {
	lengths: Measurements.Context,
	containingInlineSize: number?,
	borderWidths: { [string]: number }?,
}

export type Margin = { auto: boolean, value: number }
export type Metrics = {
	boxSizing: string,
	padding: { [string]: number },
	border: { [string]: number },
	margin: { [string]: Margin },
	horizontalInset: number,
	verticalInset: number,
}

export type Geometry = {
	width: number,
	height: number,
	contentX: number,
	contentY: number,
	contentWidth: number,
	contentHeight: number,
	paddingWidth: number,
	paddingHeight: number,
}

local BoxModel = {}
local sides = { "top", "right", "bottom", "left" }
local defaultBorderWidths: { [string]: number } = { thin = 1, medium = 3, thick = 5 }

local function keyword(tokens: { Types.ValueToken }?): string?
	return if tokens and #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

local function lengthContext(context: Context, allowPercentage: boolean): Measurements.Context
	local options = table.clone(context.lengths)
	options.allowRatio = nil
	options.percentageDimension = nil
	options.percentageBasis = nil
	if allowPercentage then
		options.percentageDimension = "length"
		options.percentageBasis = context.containingInlineSize
	end
	return options
end

local function length(
	tokens: { Types.ValueToken },
	context: Measurements.Context,
	allowPercentage: boolean
): (number?, string?)
	-- Unitless literal zero is already a complete CSS length. It needs no
	-- quantity allocation or context conversion; other spellings and math
	-- expressions retain the ordinary numeric validation below.
	if #tokens == 1 and tokens[1].kind == "number" and tokens[1].value == "0" then
		return 0, nil
	end
	local value, failure = Measurements.resolve(tokens, context)
	if not value then
		return nil, failure
	end
	if value.dimension == "number" and value.value == 0 then
		return 0, nil
	end
	if value.dimension ~= "length" then
		return nil, "expected-length"
	end
	if not allowPercentage and (value.percentage or 0) ~= 0 then
		return nil, "percentage-not-allowed"
	end
	local resolved = Measurements.toScalar(value, context)
	if resolved == nil then
		return nil, "containing-inline-size-required"
	end
	return resolved, nil
end

local function nonnegative(value: number, tokens: { Types.ValueToken }): (number?, string?)
	if value >= 0 then
		return value, nil
	end
	-- Math expressions in a nonnegative range clamp at computed/used value time.
	if #tokens == 1 and tokens[1].kind == "function" then
		return 0, nil
	end
	return nil, "negative-length-not-allowed"
end

function BoxModel.resolveMetrics(style: Types.ComputedStyle, context: Context): (Metrics?, string?)
	local physical, mappingFailure = LogicalProperties.view(style)
	if not physical then
		return nil, mappingFailure
	end
	local properties = physical.properties
	for property, failure in physical.unresolved do
		if
			property == "box-sizing"
			or property:sub(1, 8) == "padding-"
			or property:sub(1, 7) == "margin-"
			or (property:sub(1, 7) == "border-" and (property:sub(-6) == "-width" or property:sub(-6) == "-style"))
		then
			return nil, `{property}:{failure}`
		end
	end
	local sizing = keyword(properties["box-sizing"]) or "content-box"
	if sizing ~= "content-box" and sizing ~= "border-box" then
		return nil, `unsupported-box-sizing:{sizing}`
	end
	local result: Metrics =
		{ boxSizing = sizing, padding = {}, border = {}, margin = {}, horizontalInset = 0, verticalInset = 0 }
	-- Evaluation reads these contexts. Each percentage policy needs one owned
	-- copy for this measurement, independent of the number of populated sides.
	local percentages: Measurements.Context? = nil
	local absoluteLengths: Measurements.Context? = nil
	for _, side in sides do
		local padding = properties["padding-" .. side]
		local paddingValue = 0
		if padding then
			percentages = percentages or lengthContext(context, true)
			local value, failure = length(padding, percentages, true)
			if value == nil then
				return nil, `padding-{side}:{failure or "invalid"}`
			end
			local positive, rangeFailure = nonnegative(value, padding)
			if positive == nil then
				return nil, `padding-{side}:{rangeFailure or "invalid"}`
			end
			paddingValue = positive
		end
		result.padding[side] = paddingValue
		local margin = properties["margin-" .. side]
		if keyword(margin) == "auto" then
			result.margin[side] = { auto = true, value = 0 }
		elseif margin then
			percentages = percentages or lengthContext(context, true)
			local value, failure = length(margin, percentages, true)
			if value == nil then
				return nil, `margin-{side}:{failure or "invalid"}`
			end
			result.margin[side] = { auto = false, value = value }
		else
			result.margin[side] = { auto = false, value = 0 }
		end
		local borderStyle = keyword(properties[`border-{side}-style`]) or "none"
		local borderWidth = properties[`border-{side}-width`]
		if borderStyle == "none" or borderStyle == "hidden" then
			result.border[side] = 0
		else
			local name = keyword(borderWidth) or (if not borderWidth then "medium" else nil)
			local value: number?
			if name then
				local widths = context.borderWidths or defaultBorderWidths
				value = widths[name]
				if value == nil then
					return nil, `unknown-border-width:{name}`
				end
			elseif borderWidth then
				absoluteLengths = absoluteLengths or lengthContext(context, false)
				local resolved, failure = length(borderWidth, absoluteLengths, false)
				if resolved == nil then
					return nil, `border-{side}-width:{failure or "invalid"}`
				end
				local positive, rangeFailure = nonnegative(resolved, borderWidth)
				if positive == nil then
					return nil, `border-{side}-width:{rangeFailure or "invalid"}`
				end
				value = positive
			end
			result.border[side] = value or 0
		end
	end
	result.horizontalInset = result.padding.left + result.padding.right + result.border.left + result.border.right
	result.verticalInset = result.padding.top + result.padding.bottom + result.border.top + result.border.bottom
	return result, nil
end

-- The layout provider selects used dimensions first (including intrinsic sizing,
-- flex/grid, constraints and auto margins). This function only applies box sizing.
function BoxModel.geometry(metrics: Metrics, usedWidth: number, usedHeight: number): Geometry
	local width: number, height: number
	local contentWidth: number, contentHeight: number
	if metrics.boxSizing == "border-box" then
		contentWidth = math.max(0, usedWidth - metrics.horizontalInset)
		contentHeight = math.max(0, usedHeight - metrics.verticalInset)
		width = contentWidth + metrics.horizontalInset
		height = contentHeight + metrics.verticalInset
	else
		contentWidth, contentHeight = math.max(0, usedWidth), math.max(0, usedHeight)
		width = contentWidth + metrics.horizontalInset
		height = contentHeight + metrics.verticalInset
	end
	return {
		width = width,
		height = height,
		contentX = metrics.border.left + metrics.padding.left,
		contentY = metrics.border.top + metrics.padding.top,
		contentWidth = contentWidth,
		contentHeight = contentHeight,
		paddingWidth = width - metrics.border.left - metrics.border.right,
		paddingHeight = height - metrics.border.top - metrics.border.bottom,
	}
end

function BoxModel.fromBorderBox(metrics: Metrics, width: number, height: number): Geometry
	if metrics.boxSizing == "content-box" then
		return BoxModel.geometry(metrics, width - metrics.horizontalInset, height - metrics.verticalInset)
	end
	return BoxModel.geometry(metrics, width, height)
end

return BoxModel
