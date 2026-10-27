--!strict

local Types = require(script.Parent.Types)
local FlexTypes = require(script.Parent.FlexTypes)
local FlexSizing = require(script.Parent.FlexSizing)
local ListLayout = require(script.Parent.ListLayout)
local Measurements = require(script.Parent.Measurements)

export type Line = { used: { FlexTypes.UsedItem }, placement: ListLayout.Plan, y: number }
export type Result = { lines: { Line }, used: { FlexTypes.UsedItem }, height: number }
type Ranked = { item: FlexTypes.Item, order: number, index: number, outer: number }
local FlexLines = {}

local function word(style: Types.ComputedStyle, name: string, initial: string): (string?, string?)
	if style.unresolved[name] then
		return nil, `{name}:{style.unresolved[name]}`
	end
	local tokens = style.properties[name]
	if not tokens then
		return initial, nil
	end
	if #tokens == 1 and tokens[1].kind == "word" then
		return string.lower(tokens[1].value), nil
	end
	return nil, `wrapped-flex-value-required:{name}`
end

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function reverseCross(style: Types.ComputedStyle, property: string): Types.ComputedStyle
	local value = word(style, property, if property == "align-items" then "normal" else "auto")
	local swapped = if value == "flex-end"
		then "flex-start"
		elseif value == "flex-start" or value == "normal" or value == "stretch" then "flex-end"
		else nil
	if not swapped then
		return style
	end
	local result = table.clone(style)
	result.properties = table.clone(style.properties)
	result.properties[property] = { { kind = "word", value = swapped } }
	return result
end

function FlexLines.resolve(
	style: Types.ComputedStyle,
	items: { FlexTypes.Item },
	context: FlexTypes.Context
): (Result?, string?)
	local wrap, failure = word(style, "flex-wrap", "nowrap")
	if wrap ~= "wrap" and wrap ~= "wrap-reverse" then
		return nil, failure or "wrapped-flex-required"
	end
	local flow, flowFailure = word(style, "flex-direction", "row")
	if flow ~= "row" and flow ~= "row-reverse" then
		return nil, flowFailure or "wrapped-column-provider-required"
	end
	local align, alignFailure = word(style, "align-content", "normal")
	if not align then
		return nil, alignFailure
	end
	local lineStyle = table.clone(style)
	lineStyle.properties = table.clone(style.properties)
	lineStyle.properties["flex-wrap"] = { { kind = "word", value = "nowrap" } }
	local prepared, prepareFailure = FlexSizing.prepare(lineStyle, items, context)
	if not prepared then
		return nil, prepareFailure
	end
	local ranked: { Ranked } = {}
	for index, entry in prepared.items do
		if entry.ratio then
			return nil, "wrapped-flex-ratio-provider-required"
		end
		local order, orderFailure = ListLayout.order(items[index].style)
		if order == nil then
			return nil, orderFailure
		end
		local base = entry.basis or entry.width or entry.flexBase
		if base == nil then
			return nil, "measured-flex-base-required"
		end
		local outer = math.max(
			entry.metrics.horizontalInset,
			entry.minWidth,
			math.min(base, entry.maxWidth or math.huge)
		) + entry.metrics.margin.left.value + entry.metrics.margin.right.value
		if not finite(outer) then
			return nil, "wrapped-flex-width-overflow"
		end
		table.insert(ranked, { item = items[index], order = order, index = index, outer = outer })
	end
	table.sort(ranked, function(a: Ranked, b: Ranked): boolean
		return if a.order == b.order then a.index < b.index else a.order < b.order
	end)
	local groups: { { FlexTypes.Item } } = {}
	local current: { FlexTypes.Item } = {}
	local occupied: number = 0
	for _, entry in ranked do
		local nextWidth = occupied + (if #current > 0 then prepared.gap else 0) + entry.outer
		if not finite(nextWidth) then
			return nil, "wrapped-flex-width-overflow"
		end
		if #current > 0 and nextWidth > context.width then
			table.insert(groups, current)
			current = {}
			occupied = 0
			nextWidth = entry.outer
		end
		table.insert(current, entry.item)
		occupied = nextWidth
	end
	if #current > 0 then
		table.insert(groups, current)
	end
	local rowGap: number = 0
	local gapWord, gapFailure = word(style, "row-gap", "normal")
	if style.unresolved["row-gap"] then
		return nil, gapFailure
	end
	if gapWord ~= "normal" then
		local options = table.clone(context.lengths)
		options.percentageDimension = "length"
		options.percentageBasis = if context.autoHeight or context.heightDefinite == false
			then 0
			else context.percentageHeightBasis or context.height
		local tokens = style.properties["row-gap"]
		if not tokens then
			return nil, gapFailure
		end
		local value, reason = Measurements.resolve(tokens, options)
		if not value or (value.dimension ~= "length" and not (value.dimension == "number" and value.value == 0)) then
			return nil, reason or "wrapped-row-gap-required"
		end
		local scalar = Measurements.toScalar(value, options)
		if scalar == nil or not finite(scalar) then
			return nil, "invalid-wrapped-row-gap"
		end
		if scalar < 0 and not (#tokens == 1 and tokens[1].kind == "function") then
			return nil, "negative-wrapped-row-gap"
		end
		rowGap = math.max(0, scalar)
	end
	local heights: { number } = {}
	local natural = rowGap * math.max(0, #groups - 1)
	local pending = false
	for index, group in groups do
		local measure = table.clone(context)
		measure.measureCross = true
		measure.minHeight = nil
		measure.maxHeight = nil
		local result, reason, height = FlexSizing.resolve(lineStyle, group, measure)
		if reason == "pending-text-measurement" then
			pending = true
		elseif not result or height == nil then
			return nil, reason
		else
			heights[index] = height
			natural += height
		end
	end
	if pending then
		return nil, "pending-text-measurement"
	end
	if not finite(natural) then
		return nil, "wrapped-flex-height-overflow"
	end
	local height = if context.autoHeight
		then math.max(context.minHeight or 0, math.min(natural, context.maxHeight or math.huge))
		else context.height
	if not finite(height) or height < 0 then
		return nil, "invalid-wrapped-flex-height"
	end
	local free = height - natural
	local offset, extra = 0, 0
	if #groups == 1 and not context.autoHeight then
		heights[1] = height
		free = 0
	end
	if align == "normal" or align == "stretch" then
		if free > 0 and #groups > 0 then
			for index in heights do
				heights[index] += free / #groups
			end
		end
	elseif align == "flex-end" then
		offset = free
	elseif align == "end" then
		offset = if wrap == "wrap-reverse" then 0 else free
	elseif align == "start" then
		offset = if wrap == "wrap-reverse" then free else 0
	elseif align == "center" then
		offset = free / 2
	elseif align == "space-between" or align == "space-around" or align == "space-evenly" then
		if free < 0 then
			return nil, "wrapped-flex-overflow-distribution-provider-required"
		end
		if #groups > 0 then
			if align == "space-between" then
				extra = if #groups > 1 then free / (#groups - 1) else 0
			else
				extra = free / (if align == "space-around" then #groups else #groups + 1)
				offset = if align == "space-around" then extra / 2 else extra
			end
		end
	elseif align ~= "flex-start" then
		return nil, "wrapped-flex-align-content-provider-required"
	end
	local lines: { Line } = {}
	local used: { FlexTypes.UsedItem } = {}
	local placementStyle = if wrap == "wrap-reverse" then reverseCross(lineStyle, "align-items") else lineStyle
	for index, group in groups do
		local lineContext = table.clone(context)
		lineContext.autoHeight = false
		lineContext.measureCross = nil
		lineContext.height = heights[index]
		lineContext.percentageHeightBasis = if context.autoHeight or context.heightDefinite == false
			then nil
			else context.percentageHeightBasis or context.height
		lineContext.heightDefinite = not context.autoHeight and context.heightDefinite ~= false
		lineContext.minHeight = nil
		lineContext.maxHeight = nil
		local resolved, reason = FlexSizing.resolve(lineStyle, group, lineContext)
		if not resolved then
			return nil, reason
		end
		local placements: { ListLayout.Item } = {}
		for itemIndex, size in resolved do
			table.insert(used, size)
			local item = group[itemIndex]
			table.insert(placements, {
				node = size.node,
				style = if wrap == "wrap-reverse" then reverseCross(item.style, "align-self") else item.style,
				metrics = item.metrics,
				width = size.width,
				height = size.height,
			})
		end
		local placement, placementFailure = ListLayout.resolve(placementStyle, placements, {
			width = context.width,
			height = heights[index],
			lengths = context.lengths,
			relativePositioning = context.relativePositioning,
		})
		if not placement then
			return nil, placementFailure
		end
		table.insert(lines, {
			used = resolved,
			placement = placement,
			y = if wrap == "wrap-reverse" then height - offset - heights[index] else offset,
		})
		offset += heights[index] + rowGap + extra
	end
	return { lines = lines, used = used, height = height }, nil
end

return FlexLines
