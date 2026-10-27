--!strict

local Types = require(script.Parent.Types)
local TextSegments = require(script.Parent.TextSegments)
local SceneTypes = require(script.Parent.SceneTypes)
local BoxModel = require(script.Parent.BoxModel)
local Measurements = require(script.Parent.Measurements)
local LogicalProperties = require(script.Parent.LogicalProperties)
local Whitespace = require(script.Parent.Whitespace)
local FlexTypes = require(script.Parent.FlexTypes)
local FlexSizing = require(script.Parent.FlexSizing)
local AspectRatio = require(script.Parent.AspectRatio)
local ListLayout = require(script.Parent.ListLayout)
local Display = require(script.Parent.Display)
local BoxChildren = require(script.Parent.BoxChildren)
local FlexLines = require(script.Parent.FlexLines)

export type Intrinsic = FlexTypes.Intrinsic
export type Request = {
	node: Types.Node,
	style: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	lengths: Measurements.Context,
	snapshot: SceneTypes.Snapshot,
	width: number,
	-- False for an intrinsic-width probe. Width is then a zero scratch value,
	-- not a CSS percentage basis or a used-size constraint.
	widthDefinite: boolean?,
	height: number?,
	flow: string,
	-- False only when the sizing frontend needs no intrinsic inline quantities.
	-- Omission retains the complete intrinsic request for existing callers.
	inlineSizeRequired: boolean?,
	-- Reuse the content formatter for an out-of-flow auto-height subject.
	absolute: boolean?,
}
export type Provider = (Request) -> (Intrinsic?, string?)
export type Result = {
	-- Already resolved sizing inputs, keyed by source node for the formatter.
	-- This is the existing per-call item map, not a retained metrics cache.
	inputs: { [Types.Node]: FlexTypes.Item }?,
	used: { FlexTypes.UsedItem },
	placement: ListLayout.Plan,
	height: number,
	lines: { FlexLines.Line }?,
}

local FlexScene = {}

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
	return nil, `flex-scene-value-required:{property}`
end

local function empty(node: Types.Node, style: Types.ComputedStyle, snapshot: SceneTypes.Snapshot): (boolean?, string?)
	if node.tag == "input" or node.tag == "textarea" or node.tag == "img" then
		-- Replaced content is not an empty non-replaced CSS box.
		return false, nil
	end
	local children, childrenFailure = BoxChildren.resolve(node, snapshot)
	if not children then
		return nil, childrenFailure
	end
	for _, child in children do
		local childStyle = snapshot.styles[child]
		if not childStyle then
			return nil, "missing-flex-intrinsic-child-style"
		end
		local display, displayFailure = Display.resolve(childStyle)
		if not display then
			return nil, displayFailure
		end
		if display == "none" then
			continue
		end
		local position, positionFailure = word(childStyle, "position", "static")
		if not position then
			return nil, positionFailure
		end
		if position ~= "absolute" and position ~= "fixed" then
			return false, nil
		end
	end
	local content = word(style, "content", "normal")
	if content ~= "normal" and content ~= "none" then
		return false, nil
	end
	if TextSegments.has(node.textAfter) then
		return false, nil
	end
	if node.text == "" then
		return true, nil
	end
	local display = Display.resolve(style)
	if (display == "flex" or display == "inline-flex") and node.text:match("^[ \t\n\r]*$") then
		return true, nil
	end
	local policy, policyFailure = Whitespace.resolve(style)
	if not policy then
		return nil, policyFailure
	end
	local atoms, failure = Whitespace.process({ { source = node, text = node.text, policy = policy } })
	if not atoms then
		return nil, failure
	end
	for _, atom in atoms do
		if not atom.discarded and (atom.kind ~= "space" or not atom.collapsible) then
			return false, nil
		end
	end
	return true, nil
end

local function prepareChild(child: Types.Node, snapshot: SceneTypes.Snapshot): (Types.ComputedStyle?, string?, string?)
	local source = snapshot.styles[child]
	if not source then
		return nil, nil, "missing-flex-scene-child-style"
	end
	local style, mappingFailure = LogicalProperties.view(source)
	if not style then
		return nil, nil, mappingFailure
	end
	local display, displayFailure = Display.resolve(style)
	if not display then
		return nil, nil, displayFailure
	end
	if display == "none" then
		return style, nil, nil
	end
	local position, positionFailure = word(style, "position", "static")
	if not position then
		return nil, nil, positionFailure
	end
	return style, position, nil
end

-- A retained in-flow layout still validates new/changed excluded children.
function FlexScene.validateChildren(
	node: Types.Node,
	snapshot: SceneTypes.Snapshot,
	anonymous: { [Types.Node]: FlexTypes.Item }?,
	ordered: { Types.Node }?
): (boolean, string?)
	if TextSegments.has(node.textAfter) and not anonymous then
		return false, "ordered-flex-text-provider-required"
	end
	local children: { Types.Node }? = ordered
	local failure: string? = nil
	if not children then
		children, failure = BoxChildren.resolve(node, snapshot)
	end
	if not children then
		return false, failure
	end
	for _, child in children do
		if anonymous and anonymous[child] then
			continue
		end
		local style, _, reason = prepareChild(child, snapshot)
		if not style then
			return false, reason
		end
	end
	return true, nil
end

function FlexScene.resolve(
	node: Types.Node,
	style: Types.ComputedStyle,
	snapshot: SceneTypes.Snapshot,
	context: FlexTypes.Context,
	getLengths: (Types.ComputedStyle) -> Measurements.Context,
	intrinsic: Provider?,
	leading: FlexTypes.Item?,
	anonymous: { [Types.Node]: FlexTypes.Item }?,
	ordered: { Types.Node }?
): (Result?, string?)
	local flow, flowFailure = word(style, "flex-direction", "row")
	if not flow then
		return nil, flowFailure
	end
	local horizontal = flow == "row" or flow == "row-reverse"
	local items: { FlexTypes.Item } = {}
	if TextSegments.has(node.textAfter) and not anonymous then
		return nil, "ordered-flex-text-provider-required"
	end
	local byNode: { [Types.Node]: FlexTypes.Item } = {}
	if leading then
		table.insert(items, leading)
		byNode[leading.node] = leading
	end
	local children: { Types.Node }? = ordered
	local childrenFailure: string? = nil
	if not children then
		children, childrenFailure = BoxChildren.resolve(node, snapshot)
	end
	if not children then
		return nil, childrenFailure
	end
	for _, child in children do
		local supplied = anonymous and anonymous[child]
		if supplied then
			table.insert(items, supplied)
			byNode[child] = supplied
			continue
		end
		local childStyle, position, mappingFailure = prepareChild(child, snapshot)
		if not childStyle then
			return nil, mappingFailure
		end
		if position == nil or position == "absolute" or position == "fixed" then
			continue
		end
		local lengths = getLengths(childStyle)
		local metrics, metricFailure =
			BoxModel.resolveMetrics(childStyle, { lengths = lengths, containingInlineSize = context.width })
		if not metrics then
			return nil, metricFailure
		end
		local item: FlexTypes.Item = {
			node = child,
			style = childStyle,
			metrics = metrics,
			lengths = lengths,
			replaced = child.tag == "input" or child.tag == "textarea" or child.tag == "img",
		}
		local isEmpty, emptyFailure = empty(child, childStyle, snapshot)
		if isEmpty == nil then
			return nil, emptyFailure
		end
		if isEmpty then
			local ratio, failure = AspectRatio.resolve(childStyle, metrics)
			if failure then
				return nil, failure
			end
			if ratio then
				-- Preserve raw content suggestions so the sizing frontend can
				-- add the ratio transfer rather than trusting a false zero minimum.
				item.minContentWidth, item.minContentHeight = metrics.horizontalInset, metrics.verticalInset
			else
				item.autoMinWidth, item.autoMinHeight = metrics.horizontalInset, metrics.verticalInset
			end
			item.flexBase = if horizontal then metrics.horizontalInset else metrics.verticalInset
			item.hypotheticalCrossSize = if horizontal then metrics.verticalInset else metrics.horizontalInset
		elseif intrinsic then
			local provider = intrinsic
			local request: Request = {
				node = child,
				style = childStyle,
				metrics = metrics,
				lengths = lengths,
				snapshot = snapshot,
				width = context.width,
				widthDefinite = context.widthDefinite,
				height = if context.autoHeight or context.heightDefinite == false then nil else context.height,
				flow = flow,
			}
			-- Wrapped rows prepare their items more than once. Keep the result
			-- within this scene call; a later request can ask for missing widths.
			local attempted, includedWidths = false, false
			local input: Intrinsic? = nil
			local failure: string? = nil
			item.resolveIntrinsic = function(inlineSizeRequired)
				if not attempted or inlineSizeRequired and not includedWidths then
					local query = table.clone(request)
					query.inlineSizeRequired = inlineSizeRequired
					input, failure = provider(query)
					attempted, includedWidths = true, inlineSizeRequired
				end
				return input, failure
			end
		end
		table.insert(items, item)
		byNode[child] = item
	end
	local wrap, wrapFailure = word(style, "flex-wrap", "nowrap")
	if not wrap then
		return nil, wrapFailure
	end
	if wrap ~= "nowrap" then
		local wrapped, failure = FlexLines.resolve(style, items, context)
		if not wrapped then
			return nil, failure
		end
		return {
			inputs = byNode,
			used = wrapped.used,
			height = wrapped.height,
			lines = wrapped.lines,
			placement = {
				width = context.width,
				height = wrapped.height,
				horizontal = horizontal,
				mainAlign = "start",
				crossAlign = "start",
				gap = 0,
				items = {},
			},
		},
			nil
	end
	local used, sizeFailure, usedHeight = FlexSizing.resolve(style, items, context)
	if not used or usedHeight == nil then
		return nil, sizeFailure
	end
	local placed: { ListLayout.Item } = {}
	for _, size in used do
		local item = byNode[size.node]
		table.insert(
			placed,
			{ node = size.node, style = item.style, metrics = item.metrics, width = size.width, height = size.height }
		)
	end
	local placement, placeFailure = ListLayout.resolve(style, placed, {
		width = context.width,
		height = usedHeight,
		lengths = context.lengths,
		relativePositioning = context.relativePositioning,
	})
	if not placement then
		return nil, placeFailure
	end
	-- Native placement uses physical order. Paint uses order-modified document
	-- order, independently of row/column reversal and RTL orientation.
	local direction = word(style, "direction", "ltr")
	local forward = not horizontal or direction == "ltr"
	if flow == "row-reverse" or flow == "column-reverse" then
		forward = not forward
	end
	local sizes: { [Types.Node]: FlexTypes.UsedItem } = {}
	for _, size in used do
		sizes[size.node] = size
	end
	local painted: { FlexTypes.UsedItem } = {}
	for index = 1, #placement.items do
		local item = placement.items[if forward then index else #placement.items - index + 1]
		table.insert(painted, sizes[item.node])
	end
	return { inputs = byNode, used = painted, placement = placement, height = usedHeight }, nil
end

return FlexScene
