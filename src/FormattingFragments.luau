--!strict

local Types = require(script.Parent.Types)
local SceneTypes = require(script.Parent.SceneTypes)
local BlockFlow = require(script.Parent.BlockFlow)
local NativeImage = require(script.Parent.NativeImage)

export type Layout = { box: SceneTypes.Box, flow: BlockFlow.Result }
export type Constraints = {
	parent: Types.Node?,
	width: number,
	height: number?,
	direction: string,
	assignedWidth: number?,
	assignedHeight: number?,
	widthDefinite: boolean?,
	heightDefinite: boolean?,
	absoluteAssignment: boolean?,
	measuredWidth: number?,
}
export type Positioned = { node: Types.Node, parent: Types.Node? }
export type Entry = {
	constraints: Constraints,
	node: Types.Node,
	boxes: { [SceneTypes.Key]: SceneTypes.Box },
	lists: { [SceneTypes.Key]: SceneTypes.List },
	styles: { [Types.Node]: Types.ComputedStyle },
	flow: BlockFlow.Result,
	ranks: number,
	positioned: { Positioned },
	owners: { [Types.Node]: Types.Node },
	immutable: boolean?,
}

local FormattingFragments = {}
-- Geometry copied from one retained fragment has the same content inputs.
-- Final placement and resource data remain live and require separate checks.
local origins: { [SceneTypes.Box]: {} } = setmetatable({}, { __mode = "k" })

function FormattingFragments.origin(box: SceneTypes.Box): {}?
	return origins[box]
end

local function copyBox(box: SceneTypes.Box, immutable: boolean?): SceneTypes.Box
	local result = table.clone(box)
	if immutable then
		return result
	end
	result.metrics = table.clone(box.metrics)
	result.metrics.border = table.clone(box.metrics.border)
	result.metrics.padding = table.clone(box.metrics.padding)
	result.metrics.margin = {}
	for name, value in box.metrics.margin do
		result.metrics.margin[name] = table.clone(value)
	end
	result.lengths = table.clone(box.lengths)
	if box.lengths.units then
		result.lengths.units = table.clone(box.lengths.units)
	end
	if box.baselines then
		result.baselines = table.clone(box.baselines)
	end
	if box.editor then
		result.editor = table.clone(box.editor)
	end
	if box.runs then
		local runs: { SceneTypes.GlyphRun } = {}
		for i, run in box.runs do
			runs[i] = table.clone(run)
		end
		result.runs = runs
	end
	return result
end

local function copyList(list: SceneTypes.List, immutable: boolean?): SceneTypes.List
	if immutable then
		return list
	end
	local plan = table.clone(list.plan)
	plan.items = {}
	for i, item in list.plan.items do
		local copy = table.clone(item)
		if item.margins then
			copy.margins = table.clone(item.margins)
		end
		plan.items[i] = copy
	end
	return { plan = plan, views = table.clone(list.views) }
end

local function copyFlow(flow: BlockFlow.Result, immutable: boolean?): BlockFlow.Result
	if immutable then
		return flow
	end
	local result = table.clone(flow)
	result.positions = table.clone(flow.positions)
	result.top, result.bottom, result.beforeBottom =
		table.clone(flow.top), table.clone(flow.bottom), table.clone(flow.beforeBottom)
	return result
end

-- Only owned capture copies are frozen. Logical nodes and computed styles stay
-- with their existing owners; native consumers share the immutable geometry.
local function freezeBox(box: SceneTypes.Box)
	local metrics = box.metrics
	for _, margin in metrics.margin do
		table.freeze(margin)
	end
	table.freeze(metrics.margin)
	table.freeze(metrics.padding)
	table.freeze(metrics.border)
	table.freeze(metrics)
	if box.lengths.units then
		table.freeze(box.lengths.units)
	end
	if box.lengths.mathRange then
		box.lengths.mathRange = table.freeze(table.clone(box.lengths.mathRange))
	end
	table.freeze(box.lengths)
	if box.baselines then
		table.freeze(box.baselines)
	end
	if box.editor then
		table.freeze(box.editor)
	end
	if box.runs then
		for _, run in box.runs do
			table.freeze(run)
		end
		table.freeze(box.runs)
	end
	table.freeze(box)
end

local function freezeList(list: SceneTypes.List)
	for _, item in list.plan.items do
		if item.margins then
			table.freeze(item.margins)
		end
		table.freeze(item)
	end
	table.freeze(list.plan.items)
	table.freeze(list.plan)
	table.freeze(list.views)
	table.freeze(list)
end

local function freezeFlow(flow: BlockFlow.Result)
	table.freeze(flow.positions)
	table.freeze(flow.top)
	table.freeze(flow.bottom)
	table.freeze(flow.beforeBottom)
	table.freeze(flow)
end

function FormattingFragments.find(entries: { Entry }, constraints: Constraints): Entry?
	for _, entry in entries do
		local a = entry.constraints
		if
			a.parent == constraints.parent
			and a.width == constraints.width
			and a.height == constraints.height
			and a.direction == constraints.direction
			and a.assignedWidth == constraints.assignedWidth
			and a.assignedHeight == constraints.assignedHeight
			and a.widthDefinite == constraints.widthDefinite
			and a.heightDefinite == constraints.heightDefinite
			and a.absoluteAssignment == constraints.absoluteAssignment
			and a.measuredWidth == constraints.measuredWidth
		then
			return entry
		end
	end
	return nil
end

-- Capture before the caller places this subtree. Geometry has private ownership;
-- resources and the final placement of positioned descendants remain live.
function FormattingFragments.capture(
	entries: { Entry },
	constraints: Constraints,
	layout: Layout,
	keys: { SceneTypes.Key },
	plan: SceneTypes.Plan,
	firstRank: number,
	lastRank: number,
	positioned: { Positioned },
	owners: { [Types.Node]: Types.Node },
	privateKeys: { Types.Node },
	immutable: boolean?
)
	-- A short logical tree can still contain a large multiline text run. Bound
	-- copied geometry as well; exceeding the cache budget keeps normal formatting.
	local cost = #keys + #privateKeys + #positioned
	for _, key in keys do
		local box = plan.boxes[key]
		if box and box.runs then
			cost += #box.runs
		end
	end
	if cost > 256 then
		return
	end
	local boxes, lists, styles = {}, {}, {}
	for _, key in keys do
		local box = plan.boxes[key]
		if box then
			local copy = copyBox(box)
			local origin = origins[box] or {}
			origins[box], origins[copy] = origin, origin
			copy.image = nil -- Resource data is resolved live, never owned by geometry.
			if copy.zIndex then
				copy.zIndex -= firstRank
			end
			if immutable then
				freezeBox(copy)
			end
			boxes[key] = copy
		end
		local list = plan.lists and plan.lists[key]
		if list then
			lists[key] = copyList(list)
			if immutable then
				freezeList(lists[key])
			end
		end
		if type(key) == "table" and plan.styles and plan.styles[key] then
			styles[key] = plan.styles[key]
		end
	end
	local privateOwners = {}
	for _, node in privateKeys do
		if plan.styles and plan.styles[node] then
			styles[node] = plan.styles[node]
		end
		privateOwners[node] = owners[node]
	end
	if #entries == 8 then
		table.remove(entries, 1)
	end
	local flow = copyFlow(layout.flow)
	if immutable then
		freezeFlow(flow)
	end
	table.insert(entries, {
		constraints = table.clone(constraints),
		node = layout.box.node,
		boxes = boxes,
		lists = lists,
		styles = styles,
		flow = flow,
		ranks = lastRank - firstRank,
		positioned = table.clone(positioned),
		owners = privateOwners,
		immutable = immutable == true,
	})
end

function FormattingFragments.restore(
	entry: Entry,
	plan: SceneTypes.Plan,
	rank: number,
	imageSource: ((Types.Node) -> (NativeImage.Data?, string?))?,
	snapshot: SceneTypes.Snapshot,
	owners: { [Types.Node]: Types.Node },
	positioned: { Positioned },
	immutable: boolean?
): (Layout?, number?, string?)
	local images: { [Types.Node]: NativeImage.Data } = {}
	if imageSource then
		for _, box in entry.boxes do
			local node = box.node
			if node.tag == "#text" or node.tag == "#flex-line" then
				continue
			end
			local data, failure = imageSource(node)
			if failure then
				return nil, nil, failure
			end
			-- Image content can blockify a flex leaf. A presence change must pass
			-- through normal formatting and its source-shape validation again.
			if (data ~= nil) ~= (box.kind == "image") then
				return nil, nil, nil
			end
			images[node] = data
		end
	end
	local share = immutable == true and entry.immutable == true
	for key, box in entry.boxes do
		local copy = copyBox(box, share)
		origins[copy] = origins[box]
		if copy.zIndex then
			copy.zIndex += rank
		end
		copy.image = images[copy.node]
		plan.boxes[key] = copy
	end
	local lists, styles = assert(plan.lists), assert(plan.styles)
	for key, list in entry.lists do
		lists[key] = copyList(list, share)
	end
	for node, style in entry.styles do
		styles[node] = style
	end
	for node, owner in entry.owners do
		owners[node] = owner
		snapshot.styles[node] = entry.styles[node]
	end
	for _, target in entry.positioned do
		table.insert(positioned, target)
	end
	return { box = plan.boxes[entry.node], flow = copyFlow(entry.flow, share) }, rank + entry.ranks, nil
end

return FormattingFragments
