--!strict

local Types = require(script.Parent.Types)
local Display = require(script.Parent.Display)
local Measurements = require(script.Parent.Measurements)
local LogicalProperties = require(script.Parent.LogicalProperties)
local BoxModel = require(script.Parent.BoxModel)
local AspectRatio = require(script.Parent.AspectRatio)
local ObjectFit = require(script.Parent.ObjectFit)
local SizingValue = require(script.Parent.SizingValue)

export type InlineContext = {
	width: number,
	height: number?,
	minContentWidth: number?,
	-- Over-constraint follows the containing block's direction, not the child.
	direction: string,
	lengths: Measurements.Context,
}
export type BlockContext = {
	-- A definite used content width can determine an automatic ratio height.
	width: number?,
	minContentHeight: number?,
	-- Only a definite containing height is a percentage basis.
	height: number?,
	autoContentHeight: number?,
	lengths: Measurements.Context,
}
export type InlineSize = { width: number, contentWidth: number, marginLeft: number, marginRight: number }
export type BlockSize = {
	height: number,
	contentHeight: number,
	marginTop: number,
	marginBottom: number,
	automatic: boolean,
	preferredContentHeight: number?,
	minimumContentHeight: number,
	maximumContentHeight: number?,
	ratioDependent: boolean?,
}
export type ReplacedContext = {
	width: number,
	height: number?,
	direction: string,
	lengths: Measurements.Context,
	natural: ObjectFit.Natural?,
}

local BlockSizing = {}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function word(tokens: { Types.ValueToken }?): string?
	return if tokens and #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

local function prepare(style: Types.ComputedStyle, metrics: BoxModel.Metrics): (Types.ComputedStyle?, string?)
	local physical, failure = LogicalProperties.view(style)
	if not physical then
		return nil, failure
	end
	for _, property in { "display", "writing-mode", "position", "float", "aspect-ratio" } do
		if physical.unresolved[property] then
			return nil, `{property}:{physical.unresolved[property]}`
		end
	end
	local properties = physical.properties
	for _, property in { "writing-mode", "position", "float" } do
		if properties[property] and not word(properties[property]) then
			return nil, `unsupported-block-value:{property}`
		end
	end
	local display, displayFailure = Display.resolve(physical)
	if not display then
		return nil, displayFailure
	end
	if display ~= "block" and display ~= "flow-root" and display ~= "flex" and display ~= "grid" then
		return nil, "normal-flow-block-box-required"
	end
	if (word(properties["writing-mode"]) or "horizontal-tb") ~= "horizontal-tb" then
		return nil, "vertical-block-sizing-provider-required"
	end
	local position = word(properties.position) or "static"
	if position ~= "static" and position ~= "relative" then
		return nil, "positioned-block-sizing-provider-required"
	end
	if (word(properties.float) or "none") ~= "none" then
		return nil, "floating-block-sizing-provider-required"
	end
	if metrics.boxSizing ~= "border-box" and metrics.boxSizing ~= "content-box" then
		return nil, "invalid-block-box-sizing"
	end
	for _, inset in { metrics.horizontalInset, metrics.verticalInset } do
		if not finite(inset) or inset < 0 then
			return nil, "invalid-block-insets"
		end
	end
	for _, side in { "top", "right", "bottom", "left" } do
		if not finite(metrics.margin[side].value) then
			return nil, "invalid-block-margin"
		end
	end
	return physical, nil
end

local dimension = SizingValue.resolve

local function margins(metrics: BoxModel.Metrics, a: string, b: string): (number, number)
	local first, second = metrics.margin[a], metrics.margin[b]
	return if first.auto then 0 else first.value, if second.auto then 0 else second.value
end

local function automaticRatioMinimum(
	style: Types.ComputedStyle,
	property: string,
	content: number?,
	maximum: number?
): (number?, string?)
	local tokens = style.properties[property]
	if tokens and word(tokens) ~= "auto" then
		return 0, nil
	end
	local scrollable = false
	for _, axis in { "x", "y" } do
		local name = `overflow-{axis}`
		if style.unresolved[name] then
			return nil, style.unresolved[name]
		end
		local value = word(style.properties[name]) or (if not style.properties[name] then "visible" else nil)
		if value == "hidden" or value == "auto" or value == "scroll" then
			scrollable = true
		elseif value ~= "visible" and value ~= "clip" then
			return nil, "ratio-minimum-overflow-provider-required"
		end
	end
	if scrollable then
		return 0, nil
	end
	if content == nil then
		return nil, `ratio-min-content-required:{property}`
	end
	if not finite(content) or content < 0 then
		return nil, "invalid-ratio-min-content-size"
	end
	return math.min(content, maximum or math.huge), nil
end

-- Non-replaced boxes participating in normal block flow only. Flex/grid item
-- sizing, replaced elements and float avoidance belong to their own providers.
function BlockSizing.resolveInline(
	style: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	context: InlineContext
): (InlineSize?, string?)
	if not finite(context.width) or context.width < 0 then
		return nil, "definite-block-containing-width-required"
	end
	if context.height ~= nil and (not finite(context.height) or context.height < 0) then
		return nil, "invalid-block-containing-height"
	end
	if context.direction ~= "ltr" and context.direction ~= "rtl" then
		return nil, "invalid-containing-block-direction"
	end
	local physical, failure = prepare(style, metrics)
	if not physical then
		return nil, failure
	end
	local ratio, ratioFailure = AspectRatio.resolve(physical, metrics)
	if ratioFailure then
		return nil, ratioFailure
	end
	local inset = metrics.horizontalInset
	local width, widthFailure = dimension(physical, "width", metrics, context.lengths, context.width, inset)
	local minimum, minFailure = dimension(physical, "min-width", metrics, context.lengths, context.width, inset)
	local maximum, maxFailure = dimension(physical, "max-width", metrics, context.lengths, context.width, inset)
	if widthFailure or minFailure or maxFailure then
		return nil, widthFailure or minFailure or maxFailure
	end
	if ratio and width == nil then
		local height, heightFailure =
			dimension(physical, "height", metrics, context.lengths, context.height, metrics.verticalInset)
		local minHeight, minHeightFailure =
			dimension(physical, "min-height", metrics, context.lengths, context.height, metrics.verticalInset)
		local maxHeight, maxHeightFailure =
			dimension(physical, "max-height", metrics, context.lengths, context.height, metrics.verticalInset)
		if heightFailure or minHeightFailure or maxHeightFailure then
			return nil, heightFailure or minHeightFailure or maxHeightFailure
		end
		local minTokens = physical.properties["min-height"]
		local transferredMin, transferredMax, transferFailure = AspectRatio.constraints(
			ratio,
			if minTokens
					and word(minTokens) ~= "auto"
					and not (context.height == nil and Measurements.hasPercentage(minTokens))
				then minHeight
				else nil,
			maxHeight,
			nil,
			minimum,
			maximum,
			"height",
			metrics
		)
		if transferFailure then
			return nil, transferFailure
		end
		minimum = math.max(minimum or 0, transferredMin or 0)
		maximum = if transferredMax then math.min(maximum or math.huge, transferredMax) else maximum
		if height ~= nil then
			local intrinsic, intrinsicFailure =
				automaticRatioMinimum(physical, "min-width", context.minContentWidth, maximum)
			if intrinsic == nil then
				return nil, intrinsicFailure
			end
			minimum = math.max(minimum or 0, intrinsic)
			local transferred, transferReason = AspectRatio.transfer(ratio, height, "height", metrics)
			if transferred == nil then
				return nil, transferReason
			end
			width = transferred
		end
	end
	local left, right = margins(metrics, "left", "right")
	local automatic = width == nil
	local tentative = width or math.max(0, context.width - inset - left - right)
	local used = math.max(minimum or 0, math.min(tentative, maximum or math.huge))
	-- Constraining an auto width reruns the margin equation with a fixed width.
	local fixed = not automatic or used ~= tentative
	local remaining = context.width - inset - used - left - right
	if fixed and remaining >= 0 and (metrics.margin.left.auto or metrics.margin.right.auto) then
		if metrics.margin.left.auto and metrics.margin.right.auto then
			left, right = remaining / 2, remaining / 2
		elseif metrics.margin.left.auto then
			left = remaining
		else
			right = remaining
		end
	elseif context.direction == "ltr" then
		right += remaining
	else
		left += remaining
	end
	if not finite(used + inset) or not finite(left) or not finite(right) then
		return nil, "block-inline-arithmetic-overflow"
	end
	return { width = used + inset, contentWidth = used, marginLeft = left, marginRight = right }, nil
end

function BlockSizing.resolveBlock(
	style: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	context: BlockContext
): (BlockSize?, string?)
	if context.width ~= nil and (not finite(context.width) or context.width < 0) then
		return nil, "invalid-ratio-content-width"
	end
	if context.height ~= nil and (not finite(context.height) or context.height < 0) then
		return nil, "invalid-block-containing-height"
	end
	if
		context.autoContentHeight ~= nil and (not finite(context.autoContentHeight) or context.autoContentHeight < 0)
	then
		return nil, "invalid-auto-block-content-height"
	end
	local physical, failure = prepare(style, metrics)
	if not physical then
		return nil, failure
	end
	local ratio, ratioFailure = AspectRatio.resolve(physical, metrics)
	if ratioFailure then
		return nil, ratioFailure
	end
	local inset = metrics.verticalInset
	local height, heightFailure = dimension(physical, "height", metrics, context.lengths, context.height, inset)
	local minimum, minFailure = dimension(physical, "min-height", metrics, context.lengths, context.height, inset)
	local maximum, maxFailure = dimension(physical, "max-height", metrics, context.lengths, context.height, inset)
	if heightFailure or minFailure or maxFailure then
		return nil, heightFailure or minFailure or maxFailure
	end
	local ratioDependent = ratio ~= nil and height == nil
	if ratio and ratioDependent then
		if context.width == nil then
			return nil, "definite-ratio-content-width-required"
		end
		local transferred, transferFailure = AspectRatio.transfer(ratio, context.width, "width", metrics)
		if transferred == nil then
			return nil, transferFailure
		end
		local intrinsic, intrinsicFailure =
			automaticRatioMinimum(physical, "min-height", context.minContentHeight, maximum)
		if intrinsic == nil then
			return nil, intrinsicFailure
		end
		minimum = math.max(minimum or 0, intrinsic)
		height = transferred
	end
	local automatic = height == nil
	local tentative = height or context.autoContentHeight
	if tentative == nil then
		return nil, "measured-auto-block-content-height-required"
	end
	local used = math.max(minimum or 0, math.min(tentative, maximum or math.huge))
	local top, bottom = margins(metrics, "top", "bottom")
	if not finite(used + inset) then
		return nil, "block-height-arithmetic-overflow"
	end
	return {
		height = used + inset,
		contentHeight = used,
		marginTop = top,
		marginBottom = bottom,
		automatic = automatic,
		preferredContentHeight = height,
		minimumContentHeight = minimum or 0,
		maximumContentHeight = maximum,
		ratioDependent = ratioDependent,
	},
		nil
end

-- Replaced normal-flow blocks use natural dimensions rather than stretching
-- an automatic width to the containing block. Reuse the ordinary margin and
-- dimension machinery after determining the coupled content sizes.
function BlockSizing.resolveReplaced(
	style: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	context: ReplacedContext
): (InlineSize?, BlockSize?, string?)
	local physical, failure = prepare(style, metrics)
	if not physical then
		return nil, nil, failure
	end
	local values: { [string]: number? } = {}
	for _, property in { "width", "height", "min-width", "max-width", "min-height", "max-height" } do
		local horizontal = property:find("width", 1, true) ~= nil
		local value, reason = dimension(
			physical,
			property,
			metrics,
			context.lengths,
			if horizontal then context.width else context.height,
			if horizontal then metrics.horizontalInset else metrics.verticalInset
		)
		if reason then
			return nil, nil, reason
		end
		values[property] = value
	end
	local width, height = values.width, values.height
	local autoWidth, autoHeight = width == nil, height == nil
	local authorRatio, ratioFailure = AspectRatio.resolve(physical, metrics)
	if ratioFailure then
		return nil, nil, ratioFailure
	end
	if authorRatio and (autoWidth or autoHeight) then
		return nil, nil, "replaced-author-ratio-sizing-provider-required"
	end
	local minWidth, minHeight = values["min-width"] or 0, values["min-height"] or 0
	local maxWidth = math.max(minWidth, values["max-width"] or math.huge)
	local maxHeight = math.max(minHeight, values["max-height"] or math.huge)
	local ratio: number? = nil
	local natural = context.natural
	if autoWidth or autoHeight then
		if not natural then
			return nil, nil, "replaced-natural-metadata-provider-required"
		end
		for _, field in { "width", "height", "ratio" } do
			local value = (natural :: { [string]: number? })[field]
			if value ~= nil and (not finite(value) or value <= 0) then
				return nil, nil, "replaced-positive-natural-dimensions-required"
			end
		end
		ratio = natural.ratio
		if not ratio and natural.width and natural.height then
			ratio = natural.width / natural.height
		end
		if ratio and (not finite(ratio) or ratio <= 0) then
			return nil, nil, "replaced-natural-ratio-range-required"
		end
	end
	if width ~= nil then
		width = math.max(minWidth, math.min(width, maxWidth))
	end
	if height ~= nil then
		height = math.max(minHeight, math.min(height, maxHeight))
	end
	if autoWidth and autoHeight then
		-- Ratio-only resources and missing fallback dimensions require the
		-- default/replaced intrinsic sizing algorithm, not block fill width.
		width = if natural then natural.width else nil
		height = if natural then natural.height else nil
		if width and not height and ratio then
			height = width / ratio
		elseif height and not width and ratio then
			width = height * ratio
		end
	elseif autoWidth then
		width = if ratio and height then height * ratio elseif natural then natural.width else nil
	elseif autoHeight then
		height = if ratio and width then width / ratio elseif natural then natural.height else nil
	end
	if width == nil or height == nil then
		return nil, nil, "replaced-default-intrinsic-size-provider-required"
	end
	local usedWidth: number = width :: number
	local usedHeight: number = height :: number
	if not finite(usedWidth) or not finite(usedHeight) then
		return nil, nil, "replaced-size-arithmetic-range-required"
	end
	if autoWidth and autoHeight and ratio then
		-- CSS 2.2 10.4's coupled constraint table. Natural sizes are positive,
		-- so scale factors retain the tentative geometry without zero divides.
		if usedWidth < minWidth and usedHeight > maxHeight then
			usedWidth, usedHeight = minWidth, maxHeight
		elseif usedWidth > maxWidth and usedHeight < minHeight then
			usedWidth, usedHeight = maxWidth, minHeight
		else
			local lower = math.max(minWidth / usedWidth, minHeight / usedHeight)
			local upper = math.min(maxWidth / usedWidth, maxHeight / usedHeight)
			local scale = if upper < 1 then upper elseif lower > 1 then lower else 1
			usedWidth *= scale
			usedHeight *= scale
		end
	end
	usedWidth = math.max(minWidth, math.min(usedWidth, maxWidth))
	usedHeight = math.max(minHeight, math.min(usedHeight, maxHeight))
	local fixed = table.clone(physical)
	fixed.properties = table.clone(physical.properties)
	fixed.properties["aspect-ratio"] = nil
	local borderBox = metrics.boxSizing == "border-box"
	fixed.properties.width = {
		{
			kind = "dimension",
			value = string.format("%.17g", usedWidth + (if borderBox then metrics.horizontalInset else 0)),
			unit = "px",
		},
	}
	fixed.properties.height = {
		{
			kind = "dimension",
			value = string.format("%.17g", usedHeight + (if borderBox then metrics.verticalInset else 0)),
			unit = "px",
		},
	}
	local inline, inlineFailure = BlockSizing.resolveInline(
		fixed,
		metrics,
		{ width = context.width, height = context.height, direction = context.direction, lengths = context.lengths }
	)
	if not inline then
		return nil, nil, inlineFailure
	end
	local block, blockFailure = BlockSizing.resolveBlock(
		fixed,
		metrics,
		{ width = inline.contentWidth, height = context.height, lengths = context.lengths }
	)
	return inline, block, blockFailure
end

return BlockSizing
