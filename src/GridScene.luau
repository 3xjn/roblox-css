--!strict

local Types = require(script.Parent.Types)
local SceneTypes = require(script.Parent.SceneTypes)
local FlexScene = require(script.Parent.FlexScene)
local GridTracks = require(script.Parent.GridTracks)
local GridPlacement = require(script.Parent.GridPlacement)
local GridAutoPlacement = require(script.Parent.GridAutoPlacement)
local GridIntrinsicSizing = require(script.Parent.GridIntrinsicSizing)
local GridTrackSizing = require(script.Parent.GridTrackSizing)
local GridItems = require(script.Parent.GridItems)
local LogicalProperties = require(script.Parent.LogicalProperties)
local BoxChildren = require(script.Parent.BoxChildren)
local BoxModel = require(script.Parent.BoxModel)
local Measurements = require(script.Parent.Measurements)
local Display = require(script.Parent.Display)
local ListLayout = require(script.Parent.ListLayout)
local WorkQueue = require(script.Parent.WorkQueue)

export type Context = { width: number, height: number?, lengths: Measurements.Context }
export type Used = {
	item: GridItems.Item,
	width: number,
	height: number,
	widthDefinite: boolean,
	heightDefinite: boolean,
	x: number,
	y: number,
	areaWidth: number,
	areaHeight: number,
}
export type Result = { used: { Used }, height: number, columns: GridTrackSizing.Result, rows: GridTrackSizing.Result }

local GridScene = {}

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
	return nil, `grid-value-provider-required:{property}`
end

local function tracks(
	style: Types.ComputedStyle,
	property: string,
	implicit: boolean,
	units: Measurements.Context
): (GridTracks.List?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local tokens: { Types.ValueToken } = style.properties[property]
		or { { kind = "word", value = if implicit then "auto" else "none" } }
	return GridTracks.parse(tokens, { implicit = implicit, lengths = units })
end

local function gap(
	style: Types.ComputedStyle,
	property: string,
	basis: number?,
	units: Measurements.Context
): (number?, string?)
	local normal = word(style, property, "normal")
	if normal == "normal" then
		return 0, nil
	end
	if style.unresolved[property] then
		return nil, style.unresolved[property]
	end
	local context = table.clone(units)
	context.percentageDimension = "length"
	context.percentageBasis = basis
	context.mathRange = { minimum = 0, maximum = 1.7976931348623157e308 }
	local tokens: { Types.ValueToken } = style.properties[property] or { { kind = "number", value = "0" } }
	local quantity, failure = Measurements.resolve(tokens, context)
	if not quantity then
		if
			basis == nil
			and Measurements.hasPercentage(tokens)
			and (failure == "percentage-basis-required" or failure == "math-range-percentage-basis-required")
		then
			return 0, nil
		end
		return nil, `grid-gap-provider-required:{failure or "unknown"}`
	end
	if quantity.dimension ~= "length" and not (quantity.dimension == "number" and quantity.value == 0) then
		return nil, "grid-gap-length-required"
	end
	if basis == nil and Measurements.hasPercentage(tokens) then
		return 0, nil
	end
	local result = Measurements.toScalar(quantity, context)
	if result == nil or result ~= result or result < 0 or result >= math.huge then
		return nil, "invalid-grid-gap"
	end
	return result, nil
end

local function materialize(
	explicit: { GridTracks.Track },
	automatic: { GridTracks.Track },
	first: number,
	last: number
): { GridTracks.Track }
	local result = {}
	for index = first, last - 1 do
		WorkQueue.checkpoint()
		local definition = explicit[index]
		if not definition then
			local offset = if index < 1 then index - 1 else index - #explicit - 1
			definition = automatic[offset % #automatic + 1]
		end
		table.insert(result, definition)
	end
	return result
end

local function flow(style: Types.ComputedStyle): (("row" | "column")?, boolean?, string?)
	if style.unresolved["grid-auto-flow"] then
		return nil, nil, style.unresolved["grid-auto-flow"]
	end
	local direction: ("row" | "column")? = nil
	local dense = false
	for _, token in style.properties["grid-auto-flow"] or { { kind = "word", value = "row" } } do
		if token.kind == "space" or token.kind == "comment" then
			continue
		end
		local value = if token.kind == "word" then string.lower(token.value) else ""
		if value == "dense" and not dense then
			dense = true
		elseif (value == "row" or value == "column") and not direction then
			direction = value
		else
			return nil, nil, "grid-auto-flow-provider-required"
		end
	end
	return direction or "row", dense, nil
end

local function alignment(
	style: Types.ComputedStyle,
	property: string,
	initial: string,
	horizontal: boolean
): (string?, string?)
	local value, failure = word(style, property, initial)
	if not value then
		return nil, failure
	end
	if value == "auto" then
		value = initial
	end
	if value == "self-start" or value == "self-end" then
		local direction, reason = word(style, "direction", "ltr")
		if not direction then
			return nil, reason
		end
		local start = value == "self-start"
		if horizontal and direction == "rtl" then
			start = not start
		end
		return if start then "start" else "end", nil
	end
	if value == "left" and horizontal then
		return "start", nil
	end
	if value == "right" and horizontal then
		return "end", nil
	end
	if
		value == "normal"
		or value == "stretch"
		or value == "start"
		or value == "end"
		or value == "center"
		or value == "flex-start"
		or value == "flex-end"
	then
		return value, nil
	end
	return nil, `grid-alignment-provider-required:{property}:{value}`
end

local function distribution(style: Types.ComputedStyle, property: string): (string?, string?)
	local value, failure = word(style, property, "normal")
	if not value then
		return nil, failure
	end
	if
		value == "normal"
		or value == "stretch"
		or value == "start"
		or value == "end"
		or value == "center"
		or value == "flex-start"
		or value == "flex-end"
		or value == "space-between"
		or value == "space-around"
		or value == "space-evenly"
	then
		return value, nil
	end
	return nil, `grid-distribution-provider-required:{property}:{value}`
end

local function distribute(result: GridTrackSizing.Result, available: number, mode: string): { number }
	local free = available - result.extent
	local start, extra = 0, 0
	local count = #result.sizes
	if mode == "end" or mode == "flex-end" then
		start = free
	elseif mode == "center" then
		start = free / 2
	elseif free > 0 and count > 0 then
		if mode == "space-between" and count > 1 then
			extra = free / (count - 1)
		elseif mode == "space-around" then
			extra = free / count
			start = extra / 2
		elseif mode == "space-evenly" then
			extra = free / (count + 1)
			start = extra
		end
	end
	local offsets = {}
	for index, offset in result.offsets do
		offsets[index] = offset + start + (index - 1) * extra
	end
	return offsets
end

local function areaSize(sizes: GridTrackSizing.Result, offsets: { number }, first: number, last: number): number
	return offsets[last] + sizes.sizes[last] - offsets[first]
end

-- The same providers and block/flex visitor format grid items. This module
-- owns only track/item sizing and logical area placement, without native views.
function GridScene.resolve(
	node: Types.Node,
	style: Types.ComputedStyle,
	snapshot: SceneTypes.Snapshot,
	context: Context,
	getLengths: (Types.ComputedStyle) -> Measurements.Context,
	intrinsic: FlexScene.Provider,
	resolveHeight: (number) -> (number?, string?)
): (Result?, string?)
	if word(style, "direction", "ltr") ~= "ltr" then
		return nil, "grid-rtl-placement-provider-required"
	end
	if word(style, "writing-mode", "horizontal-tb") ~= "horizontal-tb" then
		return nil, "grid-writing-mode-provider-required"
	end
	if node.text:find("[^ \t\n\r\f]") then
		return nil, "grid-anonymous-text-provider-required"
	end
	if word(style, "grid-template-areas", "none") ~= "none" then
		return nil, "grid-named-area-definition-provider-required"
	end
	local columns, cFailure = tracks(style, "grid-template-columns", false, context.lengths)
	local rows, rFailure = tracks(style, "grid-template-rows", false, context.lengths)
	local autoColumns, acFailure = tracks(style, "grid-auto-columns", true, context.lengths)
	local autoRows, arFailure = tracks(style, "grid-auto-rows", true, context.lengths)
	if not columns or not rows or not autoColumns or not autoRows then
		return nil, cFailure or rFailure or acFailure or arFailure
	end
	local main, dense, flowFailure = flow(style)
	if not main then
		return nil, flowFailure
	end
	local justify, jFailure = distribution(style, "justify-content")
	local align, aFailure = distribution(style, "align-content")
	local justifyItems, jiFailure = alignment(style, "justify-items", "normal", true)
	local alignItems, aiFailure = alignment(style, "align-items", "normal", false)
	if not justify or not align or not justifyItems or not alignItems then
		return nil, jFailure or aFailure or jiFailure or aiFailure
	end
	local columnGap, cgFailure = gap(style, "column-gap", context.width, context.lengths)
	local rowGap, rgFailure = gap(style, "row-gap", context.height, context.lengths)
	if columnGap == nil or rowGap == nil then
		return nil, cgFailure or rgFailure
	end
	local children, childrenFailure = BoxChildren.resolve(node, snapshot)
	if not children then
		return nil, childrenFailure
	end
	local items: { GridItems.Item } = {}
	local placements: { GridAutoPlacement.Item } = {}
	for _, child in children do
		WorkQueue.checkpoint()
		local source = snapshot.styles[child]
		if not source then
			return nil, "missing-grid-child-style"
		end
		local childStyle, mappingFailure = LogicalProperties.view(source)
		if not childStyle then
			return nil, mappingFailure
		end
		local display, displayFailure = Display.resolve(childStyle)
		if not display then
			return nil, displayFailure
		end
		if display == "none" then
			continue
		end
		local position, pFailure = word(childStyle, "position", "static")
		if position ~= "static" and position ~= "relative" then
			return nil, pFailure or "grid-positioned-item-provider-required"
		end
		if word(childStyle, "z-index", "auto") ~= "auto" then
			return nil, "grid-item-stacking-provider-required"
		end
		local units = getLengths(childStyle)
		local metrics, mFailure = BoxModel.resolveMetrics(childStyle, { lengths = units })
		if not metrics then
			return nil, `grid-item-metrics:{mFailure or "unknown"}`
		end
		local item, iFailure = GridItems.prepare(child, childStyle, metrics, units, snapshot, intrinsic)
		if not item then
			return nil, iFailure
		end
		local row, rowFailure =
			GridPlacement.resolve(childStyle, "row", { tracks = #rows.tracks, names = rows.names, lengths = units })
		local column, colFailure = GridPlacement.resolve(
			childStyle,
			"column",
			{ tracks = #columns.tracks, names = columns.names, lengths = units }
		)
		local order, oFailure = ListLayout.order(childStyle)
		if not row or not column or order == nil then
			return nil, rowFailure or colFailure or oFailure
		end
		table.insert(items, item)
		table.insert(placements, { row = row, column = column, order = order })
	end
	local placement, pFailure = GridAutoPlacement.resolve(
		placements,
		{ rows = #rows.tracks, columns = #columns.tracks, flow = main, dense = dense }
	)
	if not placement then
		return nil, pFailure
	end
	local columnDefinitions =
		materialize(columns.tracks, autoColumns.tracks, placement.columnStart, placement.columnEnd)
	local rowDefinitions = materialize(rows.tracks, autoRows.tracks, placement.rowStart, placement.rowEnd)
	local colContext: GridIntrinsicSizing.Context =
		{ lengths = context.lengths, available = context.width, gap = columnGap }
	local colInitial, ciFailure = GridIntrinsicSizing.resolve(columnDefinitions, {}, colContext)
	if not colInitial then
		return nil, ciFailure
	end
	local columnContributions: { GridIntrinsicSizing.Contribution } = {}
	for index, item in items do
		local area = placement.areas[index]
		local first, last = area.columnStart - placement.columnStart + 1, area.columnEnd - placement.columnStart
		local sizes, failure = GridItems.sizes(item, true, {
			definitions = columnDefinitions,
			initial = colInitial.tracks,
			first = first,
			last = last,
			gap = columnGap,
			trackBasis = context.width,
			minimum = item.minimumWidth,
			maximum = item.maximumWidth,
		})
		if not sizes then
			return nil, failure
		end
		table.insert(columnContributions, GridItems.contribution(sizes, first, last))
	end
	local colIntrinsic, colFailure = GridIntrinsicSizing.resolve(columnDefinitions, columnContributions, colContext)
	if not colIntrinsic then
		return nil, colFailure
	end
	local colMaximums = {}
	for _, v in columnContributions do
		table.insert(colMaximums, { first = v.first, last = v.last, maximum = v.maxContent })
	end
	local columnSizes, csFailure = GridTrackSizing.finish(colIntrinsic.tracks, {
		available = context.width,
		gap = columnGap,
		stretch = justify == "normal" or justify == "stretch",
		contributions = colMaximums,
	})
	if not columnSizes then
		return nil, csFailure
	end
	local xOffsets = distribute(columnSizes, context.width, justify)
	local widths, heights, xPositions, areaWidths = {}, {}, {}, {}
	for index, item in items do
		WorkQueue.checkpoint()
		local area = placement.areas[index]
		local first, last = area.columnStart - placement.columnStart + 1, area.columnEnd - placement.columnStart
		local width = areaSize(columnSizes, xOffsets, first, last)
		areaWidths[index] = width
		local sizes, failure = GridItems.sizes(item, true, {
			definitions = columnDefinitions,
			initial = colInitial.tracks,
			first = first,
			last = last,
			gap = columnGap,
			trackBasis = context.width,
			basis = width,
			minimum = item.minimumWidth,
			maximum = item.maximumWidth,
		})
		if not sizes then
			return nil, failure
		end
		local self, selfFailure = alignment(item.style, "justify-self", justifyItems, true)
		if not self then
			return nil, selfFailure
		end
		local used, offset, placeFailure = GridItems.place(item, sizes, true, width, self, item.maximumWidth)
		if used == nil or offset == nil then
			return nil, placeFailure
		end
		widths[index], xPositions[index] = used, xOffsets[first] + offset
		local height, heightFailure = GridItems.height(item, used)
		if height == nil then
			return nil, heightFailure
		end
		heights[index] = height
	end
	local function sizeRows(
		available: number?,
		currentGap: number
	): (GridTrackSizing.Result?, { GridTrackSizing.Track }?, string?)
		local rowContext: GridIntrinsicSizing.Context =
			{ lengths = context.lengths, available = available, gap = currentGap }
		local initial, initialFailure = GridIntrinsicSizing.resolve(rowDefinitions, {}, rowContext)
		if not initial then
			return nil, nil, initialFailure
		end
		local contributions: { GridIntrinsicSizing.Contribution } = {}
		for index, item in items do
			local area = placement.areas[index]
			local first, last = area.rowStart - placement.rowStart + 1, area.rowEnd - placement.rowStart
			local sizes, failure = GridItems.sizes(item, false, {
				definitions = rowDefinitions,
				initial = initial.tracks,
				first = first,
				last = last,
				gap = currentGap,
				trackBasis = available,
				minimum = heights[index],
				maximum = heights[index],
			})
			if not sizes then
				return nil, nil, failure
			end
			table.insert(contributions, GridItems.contribution(sizes, first, last))
		end
		local prepared, failure = GridIntrinsicSizing.resolve(rowDefinitions, contributions, rowContext)
		if not prepared then
			return nil, nil, failure
		end
		local maximums = {}
		for _, v in contributions do
			table.insert(maximums, { first = v.first, last = v.last, maximum = v.maxContent })
		end
		local used, usedFailure = GridTrackSizing.finish(
			prepared.tracks,
			{
				available = available,
				gap = currentGap,
				stretch = align == "normal" or align == "stretch",
				contributions = maximums,
			}
		)
		return used, initial.tracks, usedFailure
	end
	local rowSizes, rowInitial, rsFailure = sizeRows(context.height, rowGap)
	if not rowSizes or not rowInitial then
		return nil, rsFailure
	end
	local height, hFailure = resolveHeight(rowSizes.extent)
	if height == nil then
		return nil, hFailure
	end
	if context.height == nil or height ~= context.height then
		local finalGap, finalFailure = gap(style, "row-gap", height, context.lengths)
		if finalGap == nil then
			return nil, finalFailure
		end
		rowGap = finalGap
		rowSizes, rowInitial, rsFailure = sizeRows(height, rowGap)
		if not rowSizes or not rowInitial then
			return nil, rsFailure
		end
	end
	local finalRows, finalInitial = assert(rowSizes), assert(rowInitial)
	local yOffsets = distribute(finalRows, height, align)
	local used: { Used } = {}
	for _, index in placement.order do
		WorkQueue.checkpoint()
		local item, area = items[index], placement.areas[index]
		local first, last = area.rowStart - placement.rowStart + 1, area.rowEnd - placement.rowStart
		local areaHeight = areaSize(finalRows, yOffsets, first, last)
		local sizes, failure = GridItems.sizes(item, false, {
			definitions = rowDefinitions,
			initial = finalInitial,
			first = first,
			last = last,
			gap = rowGap,
			trackBasis = height,
			basis = areaHeight,
			minimum = heights[index],
			maximum = heights[index],
		})
		if not sizes then
			return nil, failure
		end
		local self, selfFailure = alignment(item.style, "align-self", alignItems, false)
		if not self then
			return nil, selfFailure
		end
		local usedHeight, offset, placeFailure = GridItems.place(item, sizes, false, areaHeight, self, heights[index])
		if usedHeight == nil or offset == nil then
			return nil, placeFailure
		end
		table.insert(used, {
			item = item,
			width = widths[index],
			height = usedHeight,
			widthDefinite = true,
			heightDefinite = true,
			x = xPositions[index],
			y = yOffsets[first] + offset,
			areaWidth = areaWidths[index],
			areaHeight = areaHeight,
		})
	end
	return { used = used, height = height, columns = columnSizes, rows = finalRows }, nil
end

return GridScene
