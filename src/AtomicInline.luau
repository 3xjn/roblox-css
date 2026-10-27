--!strict

local Types = require(script.Parent.Types)
local BoxChildren = require(script.Parent.BoxChildren)
local SceneTypes = require(script.Parent.SceneTypes)
local BoxModel = require(script.Parent.BoxModel)
local Measurements = require(script.Parent.Measurements)
local SizingValue = require(script.Parent.SizingValue)
local FlexScene = require(script.Parent.FlexScene)
local FlexTypes = require(script.Parent.FlexTypes)
local LineBox = require(script.Parent.LineBox)
local Typography = require(script.Parent.Typography)
local Whitespace = require(script.Parent.Whitespace)
local AspectRatio = require(script.Parent.AspectRatio)

export type Prepared = {
	node: Types.Node,
	style: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	width: number,
	height: number,
	heightDefinite: boolean,
}
export type Item = { prepared: Prepared, box: SceneTypes.Box }
export type Placement = { node: Types.Node, x: number, y: number }
export type Result = { height: number, placements: { Placement }, baselines: SceneTypes.Baselines? }

local AtomicInline = {}
local function word(style: Types.ComputedStyle, property: string, initial: string): string?
	if style.unresolved[property] then
		return nil
	end
	local tokens = style.properties[property]
	return if not tokens
		then initial
		elseif #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value)
		else nil
end
local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

-- Resolve an atomic inline's own size before its independent flex formatting
-- context is visited. The consumer's intrinsic provider retains precedence.
function AtomicInline.prepare(
	node: Types.Node,
	style: Types.ComputedStyle,
	snapshot: SceneTypes.Snapshot,
	lengths: Measurements.Context,
	width: number,
	height: number?,
	intrinsic: FlexScene.Provider
): (Prepared?, string?)
	if word(style, "float", "none") ~= "none" then
		return nil, "atomic-inline-float-provider-required"
	end
	local metrics, failure = BoxModel.resolveMetrics(style, { lengths = lengths, containingInlineSize = width })
	if not metrics then
		return nil, failure
	end
	for _, side in { "top", "right", "bottom", "left" } do
		if metrics.margin[side].value < 0 then
			return nil, "atomic-inline-negative-margin-provider-required"
		end
	end
	local preferred, preferredFailure =
		SizingValue.resolve(style, "width", metrics, lengths, width, metrics.horizontalInset)
	local minimum, minimumFailure =
		SizingValue.resolve(style, "min-width", metrics, lengths, width, metrics.horizontalInset)
	local maximum, maximumFailure =
		SizingValue.resolve(style, "max-width", metrics, lengths, width, metrics.horizontalInset)
	local cross, crossFailure = SizingValue.resolve(style, "height", metrics, lengths, height, metrics.verticalInset)
	local minCross, minCrossFailure =
		SizingValue.resolve(style, "min-height", metrics, lengths, height, metrics.verticalInset)
	local maxCross, maxCrossFailure =
		SizingValue.resolve(style, "max-height", metrics, lengths, height, metrics.verticalInset)
	if preferredFailure or minimumFailure or maximumFailure or crossFailure or minCrossFailure or maxCrossFailure then
		return nil,
			preferredFailure or minimumFailure or maximumFailure or crossFailure or minCrossFailure or maxCrossFailure
	end
	local ratio, ratioFailure = AspectRatio.resolve(style, metrics)
	if ratioFailure then return nil, ratioFailure end
	if ratio and preferred == nil and cross ~= nil then
		preferred, ratioFailure = AspectRatio.transfer(ratio, math.max(minCross or 0, math.min(cross, maxCross or math.huge)), "height", metrics)
	elseif ratio and cross == nil and preferred ~= nil then
		cross, ratioFailure = AspectRatio.transfer(ratio, math.max(minimum or 0, math.min(preferred, maximum or math.huge)), "width", metrics)
	end
	if ratioFailure then return nil, ratioFailure end
	local heightDefinite = cross ~= nil
	local measured: FlexScene.Intrinsic?
	if preferred == nil or cross == nil then
		local children, childrenFailure = BoxChildren.resolve(node, snapshot)
		if not children then
			return nil, childrenFailure
		end
		if #children == 0 and node.text == "" then
			measured = {
				minContentWidth = metrics.horizontalInset,
				maxContentWidth = metrics.horizontalInset,
				hypotheticalCrossSize = metrics.verticalInset,
			}
		else
			measured, failure = intrinsic({
				node = node,
				style = style,
				metrics = metrics,
				lengths = lengths,
				snapshot = snapshot,
				width = width,
				height = height,
				flow = "row",
			})
			if failure then
				return nil, failure
			end
		end
		if preferred == nil then
			if not measured or measured.minContentWidth == nil or measured.maxContentWidth == nil then
				return nil, "atomic-inline-intrinsic-widths-required"
			end
			if
				not finite(measured.minContentWidth)
				or not finite(measured.maxContentWidth)
				or measured.minContentWidth < metrics.horizontalInset
				or measured.maxContentWidth < measured.minContentWidth
			then
				return nil, "invalid-atomic-inline-intrinsic-widths"
			end
			local available = width - metrics.margin.left.value - metrics.margin.right.value
			preferred = math.max(
				0,
				math.min(math.max(measured.minContentWidth, available), measured.maxContentWidth)
					- metrics.horizontalInset
			)
		end
	end
	assert(preferred ~= nil)
	local usedWidth = math.max(minimum or 0, math.min(preferred, maximum or math.huge)) + metrics.horizontalInset
	if not finite(usedWidth) then
		return nil, "atomic-inline-size-overflow"
	end
	if cross == nil then
		local measure = if measured then (measured :: FlexScene.Intrinsic).measure else nil
		if measure then
			local constraints: FlexTypes.Constraints = {
				width = usedWidth - metrics.horizontalInset,
				widthMode = "exactly",
				heightMode = "undefined",
			}
			local ok, result, reason = pcall(measure, constraints)
			if not ok then
				return nil, `atomic-inline-measurement:{tostring(result)}`
			end
			if not result then
				return nil, reason or "atomic-inline-measurement-required"
			end
			if not finite(result.width) or not finite(result.height) or result.width < 0 or result.height < 0 then
				return nil, "invalid-atomic-inline-measurement"
			end
			cross = result.height
		else
			if not measured or measured.hypotheticalCrossSize == nil then
				return nil, "atomic-inline-intrinsic-height-required"
			end
			if not finite(measured.hypotheticalCrossSize) or measured.hypotheticalCrossSize < metrics.verticalInset then
				return nil, "invalid-atomic-inline-intrinsic-height"
			end
			cross = measured.hypotheticalCrossSize - metrics.verticalInset
		end
	end
	assert(cross ~= nil)
	local usedHeight = math.max(minCross or 0, math.min(cross, maxCross or math.huge)) + metrics.verticalInset
	if not finite(usedWidth) or not finite(usedHeight) then
		return nil, "atomic-inline-size-overflow"
	end
	return {
		node = node,
		style = style,
		metrics = metrics,
		width = usedWidth,
		height = usedHeight,
		heightDefinite = heightDefinite,
	},
		nil
end

-- Atomic inline boxes form actual line boxes. No blockification of the outer
-- role or native flex-list approximation is used for their line placement.
function AtomicInline.resolve(
	items: { Item },
	style: Types.ComputedStyle,
	width: number,
	fontMetrics: Typography.Metrics?
): (Result?, string?)
	local size = Typography.fontSize(style)
	local lineHeight = Typography.lineHeight(style, fontMetrics)
	if not size or not lineHeight or not fontMetrics or not fontMetrics.ascent or not fontMetrics.descent then
		return nil, "inline-strut-font-metrics-required"
	end
	local strut: LineBox.Metrics =
		{ ascent = size * fontMetrics.ascent, descent = size * fontMetrics.descent, lineHeight = lineHeight }
	local policy, failure = Whitespace.resolve(style)
	if not policy then
		return nil, failure
	end
	if not Whitespace.usesNormalWrapping(policy.wrapStyle) or word(style, "direction", "ltr") ~= "ltr" then
		return nil, "atomic-inline-line-policy-provider-required"
	end
	if
		word(style, "unicode-bidi", "normal") ~= "normal"
		or word(style, "writing-mode", "horizontal-tb") ~= "horizontal-tb"
	then
		return nil, "atomic-inline-writing-axes-provider-required"
	end
	local indent = style.properties["text-indent"]
	if style.unresolved["text-indent"] then
		return nil, "atomic-inline-text-indent-provider-required"
	elseif indent then
		local value =
			Measurements.resolve(indent, { fontSize = size, percentageBasis = width, percentageDimension = "length" })
		if not value or value.value ~= 0 or (value.percentage or 0) ~= 0 then
			return nil, "atomic-inline-text-indent-provider-required"
		end
	end
	local align = word(style, "text-align", "start")
	local lastAlign = word(style, "text-align-last", "auto")
	for _, value in { align or "", lastAlign or "" } do
		if
			value ~= "auto"
			and value ~= "start"
			and value ~= "left"
			and value ~= "end"
			and value ~= "right"
			and value ~= "center"
		then
			return nil, "atomic-inline-text-alignment-provider-required"
		end
	end
	local result: Result = { height = 0, placements = {} }
	local line: { Item } = {}
	local extent = 0
	local function flush(last: boolean): string?
		if #line == 0 then
			return nil
		end
		local runs: { LineBox.Run } = {}
		for _, item in line do
			local box, metrics = item.box, item.prepared.metrics
			if word(item.prepared.style, "vertical-align", "baseline") ~= "baseline" then
				return "atomic-inline-vertical-alignment-provider-required"
			end
			local baseline = (if box.baselines then box.baselines.first else nil)
				or (box.height + metrics.margin.bottom.value)
			local outerHeight = box.height + metrics.margin.top.value + metrics.margin.bottom.value
			table.insert(runs, {
				metrics = { ascent = 0, descent = outerHeight, lineHeight = outerHeight },
				shift = metrics.margin.top.value + baseline,
			})
		end
		local layout, reason = LineBox.resolve(strut, runs)
		if not layout then
			return reason
		end
		local effective = if last and lastAlign ~= "auto" then lastAlign else align
		local cursor = if effective == "center"
			then (width - extent) / 2
			elseif effective == "right" or effective == "end" then width - extent
			else 0
		local baseline = result.height + layout.baseline
		if not result.baselines then
			result.baselines = { first = baseline }
		end
		local baselines = assert(result.baselines)
		baselines.last = baseline
		for index, item in line do
			local margins = item.prepared.metrics.margin
			table.insert(result.placements, {
				node = item.prepared.node,
				x = cursor + margins.left.value,
				y = result.height + layout.runs[index].top + margins.top.value,
			})
			cursor += item.box.width + margins.left.value + margins.right.value
		end
		result.height += layout.height
		if not finite(result.height) or not finite(baseline) or not finite(cursor) then
			return "atomic-inline-line-overflow"
		end
		table.clear(line)
		extent = 0
		return nil
	end
	for _, item in items do
		local metrics = item.prepared.metrics
		local outerWidth = item.box.width + metrics.margin.left.value + metrics.margin.right.value
		if policy.wrap == "wrap" and #line > 0 and extent + outerWidth > width then
			local reason = flush(false)
			if reason then
				return nil, reason
			end
		end
		table.insert(line, item)
		extent += outerWidth
	end
	local reason = flush(true)
	return if reason then nil else result, reason
end

return AtomicInline
