--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local BoxModel = require(script.Parent.BoxModel)
local Display = require(script.Parent.Display)

export type Item = {
	node: Types.Node,
	style: Types.ComputedStyle,
	width: number,
	height: number,
	metrics: BoxModel.Metrics,
}
export type Margins = {
	left: number,
	right: number,
	top: number,
	bottom: number,
	autoLeft: boolean?,
	autoRight: boolean?,
	autoTop: boolean?,
	autoBottom: boolean?,
}
export type Placement = { node: Types.Node, width: number, height: number, crossAlign: string?, margins: Margins? }
export type Plan = {
	width: number,
	height: number,
	horizontal: boolean,
	mainAlign: string,
	mainStart: string?,
	crossAlign: string,
	gap: number,
	items: { Placement },
	-- UIListLayout has no per-item margins. The owning scene positions these
	-- used border boxes directly, while retaining native lists for other rows.
	manual: boolean?,
	crossStart: ("start" | "end")?,
}
-- Relative items keep their normal-flow slots. Opt in only when the caller
-- applies their paint offsets outside native list placement.
export type Context = { width: number, height: number, lengths: Measurements.Context, relativePositioning: boolean? }

local ListLayout = {}
type Ranked = { placement: Placement, order: number, index: number }

local function word(style: Types.ComputedStyle, property: string, initial: string): (string?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local tokens = style.properties[property]
	if not tokens then
		return initial, nil
	end
	if #tokens == 1 and tokens[1].kind == "word" then
		return string.lower(tokens[1].value), nil
	end
	return nil, `unsupported-list-value:{property}`
end

local function number(style: Types.ComputedStyle, property: string): (number?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local tokens = style.properties[property]
	if not tokens then
		return 0, nil
	end
	local value, failure = Measurements.resolve(tokens, {})
	if not value or value.dimension ~= "number" or value.value % 1 ~= 0 then
		return nil, failure or `integer-required:{property}`
	end
	return value.value, nil
end

local function finite(value: number): boolean
	return value >= 0 and value < math.huge
end

local sides = { "left", "right", "top", "bottom" }
local function signed(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function margins(metrics: BoxModel.Metrics): (Margins?, string?)
	local source = metrics.margin
	local needed = false
	for _, side in sides do
		local margin = source[side]
		if
			not margin
			or typeof(margin.value) ~= "number"
			or not signed(margin.value)
			or typeof(margin.auto) ~= "boolean"
		then
			return nil, "invalid-list-margin"
		end
		needed = needed or margin.auto or margin.value ~= 0
	end
	if not needed then
		return nil, nil
	end
	local left, right, top, bottom = source.left, source.right, source.top, source.bottom
	return {
		left = if left.auto then 0 else left.value,
		right = if right.auto then 0 else right.value,
		top = if top.auto then 0 else top.value,
		bottom = if bottom.auto then 0 else bottom.value,
		autoLeft = left.auto,
		autoRight = right.auto,
		autoTop = top.auto,
		autoBottom = bottom.auto,
	},
		nil
end

local function axisMargins(value: Margins?, horizontal: boolean): (number, number, boolean, boolean)
	if not value then
		return 0, 0, false, false
	end
	local nearAuto = (if horizontal then value.autoLeft else value.autoTop) == true
	local farAuto = (if horizontal then value.autoRight else value.autoBottom) == true
	return if nearAuto then 0 else (if horizontal then value.left else value.top),
		if farAuto then 0 else (if horizontal then value.right else value.bottom),
		nearAuto,
		farAuto
end

function ListLayout.order(style: Types.ComputedStyle): (number?, string?)
	return number(style, "order")
end

-- Placement of final used border-box sizes. A sizing provider must already have
-- applied flex grow/shrink, basis, stretch and min/max constraints. This module
-- does not infer those results from preferred dimensions or native defaults.
function ListLayout.resolve(style: Types.ComputedStyle, items: { Item }, context: Context): (Plan?, string?)
	if not finite(context.width) or not finite(context.height) then
		return nil, "invalid-list-content-size"
	end
	local display, failure = Display.resolve(style)
	if display ~= "flex" and display ~= "inline-flex" then
		return nil, failure or "flex-container-required"
	end
	local mode, modeFailure = word(style, "writing-mode", "horizontal-tb")
	if mode ~= "horizontal-tb" then
		return nil, modeFailure or "vertical-list-mapping-pending"
	end
	local direction, directionFailure = word(style, "direction", "ltr")
	if direction ~= "ltr" and direction ~= "rtl" then
		return nil, directionFailure or "invalid-direction"
	end
	local flow, flowFailure = word(style, "flex-direction", "row")
	if flow ~= "row" and flow ~= "row-reverse" and flow ~= "column" and flow ~= "column-reverse" then
		return nil, flowFailure or "invalid-flex-direction"
	end
	local wrap, wrapFailure = word(style, "flex-wrap", "nowrap")
	if wrap ~= "nowrap" then
		return nil, wrapFailure or "wrapped-placement-provider-required"
	end
	local horizontal = flow == "row" or flow == "row-reverse"
	local naturalForward = not horizontal or direction == "ltr"
	local forward = naturalForward
	if flow == "row-reverse" or flow == "column-reverse" then
		forward = not forward
	end
	local crossForward = horizontal or direction == "ltr"
	local property = if horizontal then "column-gap" else "row-gap"
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local gap = 0
	local tokens = style.properties[property]
	if tokens and not (#tokens == 1 and tokens[1].kind == "word" and string.lower(tokens[1].value) == "normal") then
		local options = table.clone(context.lengths)
		options.allowRatio = nil
		options.percentageDimension = "length"
		options.percentageBasis = if horizontal then context.width else context.height
		local value, gapFailure = Measurements.resolve(tokens, options)
		if not value or (value.dimension ~= "length" and not (value.dimension == "number" and value.value == 0)) then
			return nil, gapFailure or "gap-length-required"
		end
		local scalar = Measurements.toScalar(value, options)
		if scalar == nil or scalar ~= scalar or scalar == math.huge then
			return nil, "invalid-gap"
		end
		if scalar < 0 and not (#tokens == 1 and tokens[1].kind == "function") then
			return nil, "negative-gap"
		end
		gap = math.max(0, scalar)
	end
	local align, alignFailure = word(style, "align-items", "normal")
	if not align then
		return nil, alignFailure
	end
	local function cross(value: string): string?
		if value == "normal" or value == "stretch" or value == "start" or value == "flex-start" then
			return if crossForward then "start" else "end"
		elseif value == "end" or value == "flex-end" then
			return if crossForward then "end" else "start"
		elseif value == "center" then
			return "center"
		end
		return nil
	end
	local ranked: { Ranked } = {}
	local seen: { [Types.Node]: boolean } = {}
	local crossAlign: string? = nil
	local total = gap * math.max(0, #items - 1)
	local manual = false
	for index, item in items do
		if seen[item.node] then
			return nil, "duplicate-list-node"
		end
		seen[item.node] = true
		if not finite(item.width) or not finite(item.height) then
			return nil, "invalid-used-item-size"
		end
		local itemMargins, marginFailure = margins(item.metrics)
		if marginFailure then
			return nil, marginFailure
		end
		manual = manual or itemMargins ~= nil
		local position, positionFailure = word(item.style, "position", "static")
		if position ~= "static" and not (position == "relative" and context.relativePositioning) then
			return nil, positionFailure or "positioned-item-provider-required"
		end
		local selfAlign, selfFailure = word(item.style, "align-self", "auto")
		if not selfAlign then
			return nil, selfFailure
		end
		local physicalAlign = cross(if selfAlign == "auto" then align else selfAlign)
		if not physicalAlign then
			return nil, "cross-alignment-provider-required"
		end
		crossAlign = crossAlign or physicalAlign
		local order, orderFailure = ListLayout.order(item.style)
		if order == nil then
			return nil, orderFailure
		end
		table.insert(ranked, {
			placement = {
				node = item.node,
				width = item.width,
				height = item.height,
				crossAlign = physicalAlign,
				margins = itemMargins,
			},
			order = order,
			index = index,
		})
		total += if horizontal then item.width else item.height
		if itemMargins then
			total += if horizontal then itemMargins.left + itemMargins.right else itemMargins.top + itemMargins.bottom
		end
	end
	table.sort(ranked, function(a: Ranked, b: Ranked)
		if a.order == b.order then
			return if forward then a.index < b.index else a.index > b.index
		end
		return if forward then a.order < b.order else a.order > b.order
	end)
	local justify, justifyFailure = word(style, "justify-content", "normal")
	if not justify then
		return nil, justifyFailure
	end
	local mainAlign: string
	if justify == "normal" or justify == "stretch" or justify == "flex-start" then
		mainAlign = if forward then "start" else "end"
	elseif justify == "flex-end" then
		mainAlign = if forward then "end" else "start"
	elseif justify == "start" then
		mainAlign = if naturalForward then "start" else "end"
	elseif justify == "end" then
		mainAlign = if naturalForward then "end" else "start"
	elseif justify == "center" then
		mainAlign = "center"
	elseif justify == "space-between" or justify == "space-around" or justify == "space-evenly" then
		if total > (if horizontal then context.width else context.height) then
			return nil, "overflow-distribution-provider-required"
		end
		mainAlign = justify
	else
		return nil, "main-alignment-provider-required"
	end
	local placements: { Placement } = {}
	for _, item in ranked do
		table.insert(placements, item.placement)
	end
	return {
		width = context.width,
		height = context.height,
		horizontal = horizontal,
		mainAlign = mainAlign,
		mainStart = if forward then "start" else "end",
		crossAlign = crossAlign or cross(align) or "start",
		gap = gap,
		items = placements,
		manual = if manual then true else nil,
		crossStart = if manual then (if crossForward then "start" else "end") else nil,
	},
		nil
end

-- Shared logical offsets for containing-block geometry and manual margin
-- placement. Plans without margins retain native UIListLayout ownership.
function ListLayout.offsets(plan: Plan): ({ [Types.Node]: { x: number, y: number } }?, string?)
	if not finite(plan.width) or not finite(plan.height) or not finite(plan.gap) then
		return nil, "invalid-list-offset-geometry"
	end
	local count = #plan.items
	local occupied = plan.gap * math.max(0, count - 1)
	local autoCount = 0
	for _, item in plan.items do
		if not finite(item.width) or not finite(item.height) then
			return nil, "invalid-list-offset-item"
		end
		occupied += if plan.horizontal then item.width else item.height
		if item.margins then
			for _, side in sides do
				local value = (item.margins :: any)[side]
				if typeof(value) ~= "number" or not signed(value) then
					return nil, "invalid-list-offset-margin"
				end
			end
			for _, flag in { "autoLeft", "autoRight", "autoTop", "autoBottom" } do
				local value = (item.margins :: any)[flag]
				if value ~= nil and typeof(value) ~= "boolean" then
					return nil, "invalid-list-offset-margin"
				end
			end
			local near, far, nearAuto, farAuto = axisMargins(item.margins, plan.horizontal)
			occupied += near + far
			autoCount += (if nearAuto then 1 else 0) + (if farAuto then 1 else 0)
		end
	end
	local free = (if plan.horizontal then plan.width else plan.height) - occupied
	if not signed(occupied) or not signed(free) then
		return nil, "list-offset-arithmetic-range-required"
	end
	local start, gap = 0, plan.gap
	local autoShare = if autoCount > 0 and free > 0 then free / autoCount else 0
	if
		autoShare > 0
		and plan.mainAlign ~= "start"
		and plan.mainAlign ~= "end"
		and plan.mainAlign ~= "center"
		and plan.mainAlign ~= "space-between"
		and plan.mainAlign ~= "space-around"
		and plan.mainAlign ~= "space-evenly"
	then
		return nil, "list-main-offset-alignment-required"
	end
	if autoShare > 0 then
		-- Auto margins consume positive free space before justification.
	elseif plan.mainAlign == "end" then
		start = free
	elseif plan.mainAlign == "center" then
		start = free / 2
	elseif plan.mainAlign == "space-between" then
		if free < 0 then
			return nil, "overflow-distribution-provider-required"
		end
		if count > 1 then
			gap += free / (count - 1)
		elseif plan.mainStart == "end" then
			start = free
		elseif plan.mainStart ~= "start" then
			return nil, "list-start-alignment-required"
		end
	elseif plan.mainAlign == "space-around" or plan.mainAlign == "space-evenly" then
		if free < 0 then
			return nil, "overflow-distribution-provider-required"
		end
		if count > 0 then
			local extra = free / (if plan.mainAlign == "space-around" then count else count + 1)
			gap += extra
			start = if plan.mainAlign == "space-around" then extra / 2 else extra
		end
	elseif plan.mainAlign ~= "start" then
		return nil, "list-main-offset-alignment-required"
	end
	local result: { [Types.Node]: { x: number, y: number } } = {}
	for _, item in plan.items do
		if result[item.node] then
			return nil, "duplicate-list-offset-node"
		end
		local near, far, nearAuto, farAuto = axisMargins(item.margins, plan.horizontal)
		start += if nearAuto then autoShare else near
		local crossNear, crossFar, crossNearAuto, crossFarAuto = axisMargins(item.margins, not plan.horizontal)
		local crossSpace = if plan.horizontal then plan.height else plan.width
		local crossSize = if plan.horizontal then item.height else item.width
		local crossFree = crossSpace - crossSize - crossNear - crossFar
		local alignment = item.crossAlign or plan.crossAlign
		local cross: number
		if crossNearAuto or crossFarAuto then
			if crossFree > 0 then
				local share = crossFree / ((if crossNearAuto then 1 else 0) + (if crossFarAuto then 1 else 0))
				cross = if crossNearAuto then share else crossNear
			elseif plan.crossStart == "end" then
				cross = crossSpace - crossSize - crossFar
			elseif plan.crossStart == nil or plan.crossStart == "start" then
				cross = crossNear
			else
				return nil, "list-cross-start-required"
			end
		elseif alignment == "end" then
			cross = crossNear + crossFree
		elseif alignment == "center" then
			cross = crossNear + crossFree / 2
		elseif alignment == "start" then
			cross = crossNear
		else
			return nil, "list-cross-offset-alignment-required"
		end
		if start ~= start or math.abs(start) == math.huge or cross ~= cross or math.abs(cross) == math.huge then
			return nil, "list-offset-arithmetic-range-required"
		end
		result[item.node] = if plan.horizontal then { x = start, y = cross } else { x = cross, y = start }
		start += (if plan.horizontal then item.width else item.height) + (if farAuto then autoShare else far) + gap
	end
	return result, nil
end

return ListLayout
