--!strict

local Types = require(script.Parent.Types)
local TextSegments = require(script.Parent.TextSegments)
local SceneTypes = require(script.Parent.SceneTypes)
local FlexTypes = require(script.Parent.FlexTypes)
local FlexScene = require(script.Parent.FlexScene)
local TextMeasurement = require(script.Parent.TextMeasurement)
local FormattingFragments = require(script.Parent.FormattingFragments)
local Display = require(script.Parent.Display)
local LayoutStyles = require(script.Parent.LayoutStyles)
local GeneratedContent = require(script.Parent.GeneratedContent)
local FlexLayouts = require(script.Parent.FlexLayouts)

export type NodeInputs = { attributes: { [string]: boolean }, states: { [string]: boolean } }

export type Intrinsic = {
	width: number,
	height: number?,
	flow: string,
	kind: "text" | "block",
	result: FlexScene.Intrinsic,
}

export type Entry = {
	width: number,
	containingWidth: number,
	containingHeight: number?,
	direction: string,
	absolute: boolean?,
	result: FlexTypes.Size?,
	failure: string?,
}
type Inputs = {
	parent: Types.Node?,
	tag: string,
	id: string?,
	className: string,
	text: string,
	textAfter: TextSegments.After?,
	attributes: { [string]: string },
	states: { [string]: boolean },
	style: Types.ComputedStyle,
	before: Types.ComputedStyle?,
	after: Types.ComputedStyle?,
	children: { Types.Node },
	versions: { number },
	version: number,
	flowVersion: number?,
	flowChildren: { Types.Node }?,
	flowVersions: { number }?,
	count: number,
	entries: { Entry },
	intrinsics: { Intrinsic },
	fragments: { FormattingFragments.Entry },
	flex: { FlexLayouts.Entry },
}
export type Cache = {
	nodes: { [Types.Node]: Inputs },
	epoch: number?,
	viewport: Vector2?,
	initialFontSize: number?,
	root: Types.Node?,
	rootStyle: Types.ComputedStyle?,
	version: number,
	inputs: NodeInputs?,
	measureText: TextMeasurement.Reader?,
	anonymousStyle: ((Types.Node) -> (Types.ComputedStyle?, string?))?,
}

local BlockMeasurements = {}

-- Text intrinsic callbacks only return content extents. Their source subtree and
-- stable reader belong to the enclosing intrinsic record; retain successful
-- extents separately for each constraint, with fresh result ownership.
function BlockMeasurements.retainMeasure(measure: FlexTypes.Measure): FlexTypes.Measure
	local entries: { { constraints: FlexTypes.Constraints, result: FlexTypes.Size } } = {}
	return function(constraints)
		for _, entry in entries do
			local before = entry.constraints
			if
				before.width == constraints.width
				and before.height == constraints.height
				and before.widthMode == constraints.widthMode
				and before.heightMode == constraints.heightMode
			then
				return table.clone(entry.result), nil
			end
		end
		local result, failure = measure(constraints)
		if result and not failure then
			if #entries == 8 then
				table.remove(entries, 1)
			end
			table.insert(entries, { constraints = table.clone(constraints), result = table.clone(result) })
		end
		return result, failure
	end
end

local function sameMap<T>(a: { [string]: T }, b: { [string]: T }, inputs: { [string]: boolean }?): boolean
	if inputs then
		for name in inputs do
			if a[name] ~= b[name] then
				return false
			end
		end
		return true
	end
	for name, value in a do
		if b[name] ~= value then
			return false
		end
	end
	for name in b do
		if a[name] == nil then
			return false
		end
	end
	return true
end

local function sameInputs(a: NodeInputs?, b: NodeInputs?): boolean
	if not a or not b then
		return a == b
	end
	return sameMap(a.attributes, b.attributes) and sameMap(a.states, b.states)
end

local function inFlow(node: Types.Node, snapshot: SceneTypes.Snapshot): boolean
	local style = snapshot.styles[node]
	if not style then
		return true
	end -- Preserve normal missing-style diagnostics.
	local display = Display.forNode(style, node)
	if display == "none" then
		return false
	end
	if not display or display == "contents" or style.unresolved.position then
		return true
	end
	local position = style.properties.position
	return not (
		position
		and #position == 1
		and position[1].kind == "word"
		and (string.lower(position[1].value) == "absolute" or string.lower(position[1].value) == "fixed")
	)
end

local function detachedPseudo(style: Types.ComputedStyle?): boolean
	if not style then
		return true
	end
	local kind = GeneratedContent.resolve(style)
	if kind == "none" then
		return true
	end
	if kind ~= "empty" or style.unresolved.position or Display.resolve(style) == "contents" then
		return false
	end
	local position = style.properties.position
	return position ~= nil
		and #position == 1
		and position[1].kind == "word"
		and (string.lower(position[1].value) == "absolute" or string.lower(position[1].value) == "fixed")
end

local function sameFlowPseudo(a: Types.ComputedStyle?, b: Types.ComputedStyle?): boolean
	return a == b or detachedPseudo(a) and detachedPseudo(b) or LayoutStyles.sameIntrinsic(a, b)
end

function BlockMeasurements.create(): Cache
	return { nodes = {}, version = 0 }
end

-- Only successful measurements survive a scene. The host's layout epoch owns
-- external fonts/resources; subtree inputs own structural and CSS changes.
function BlockMeasurements.prepare(
	cache: Cache,
	snapshot: SceneTypes.Snapshot,
	inputs: NodeInputs?
): ({ [Types.Node]: { Entry } }, { [Types.Node]: { Intrinsic } }, {
	[Types.Node]: { FormattingFragments.Entry },
})
	local root = snapshot.roots[1]
	local rootStyle = if root then snapshot.styles[root] else nil
	if
		snapshot.layoutRevision == nil
		or cache.epoch ~= snapshot.layoutRevision
		or cache.viewport ~= snapshot.viewport
		or cache.initialFontSize ~= snapshot.initialFontSize
		or cache.root ~= root
		or (if inputs then not LayoutStyles.sameIntrinsic(cache.rootStyle, rootStyle) else cache.rootStyle ~= rootStyle)
		or not sameInputs(cache.inputs, inputs)
		or cache.measureText ~= snapshot.measureText
		or cache.anonymousStyle ~= snapshot.anonymousStyle
	then
		table.clear(cache.nodes)
	end
	if not sameInputs(cache.inputs, inputs) then
		cache.inputs = if inputs
			then { attributes = table.clone(inputs.attributes), states = table.clone(inputs.states) }
			else nil
	end
	cache.epoch, cache.viewport = snapshot.layoutRevision, snapshot.viewport
	cache.initialFontSize, cache.root, cache.rootStyle = snapshot.initialFontSize, root, rootStyle
	cache.measureText, cache.anonymousStyle = snapshot.measureText, snapshot.anonymousStyle
	local nextNodes: { [Types.Node]: Inputs } = {}
	local entries: { [Types.Node]: { Entry } } = {}
	local intrinsics: { [Types.Node]: { Intrinsic } } = {}
	local fragments: { [Types.Node]: { FormattingFragments.Entry } } = {}
	local function visit(node: Types.Node): number
		local style = snapshot.styles[node]
		if not style then
			return 0
		end
		local versions = {}
		for i, child in node.children do
			versions[i] = visit(child)
		end
		local count = 1
		for _, child in node.children do
			count += if nextNodes[child] then nextNodes[child].count else 0
		end
		local before = if snapshot.pseudoStyle then snapshot.pseudoStyle(node, "before") else nil
		local after = if snapshot.pseudoStyle then snapshot.pseudoStyle(node, "after") else nil
		local old = cache.nodes[node]
		local same = old ~= nil
			and old.parent == node.parent
			and old.tag == node.tag
			and old.id == node.id
			and old.className == node.className
			and old.text == node.text
			and TextSegments.same(old.textAfter, node.textAfter)
			and old.style == style
			and old.before == before
			and old.after == after
			and #old.children == #node.children
			and sameMap(old.attributes, node.attributes)
			and sameMap(old.states, node.states)
		if same then
			for i, child in node.children do
				if old.children[i] ~= child or old.versions[i] ~= versions[i] then
					same = false
					break
				end
			end
		end
		local flowChildren: { Types.Node }? = if same and old then old.flowChildren elseif inputs then {} else nil
		local flowVersions: { number }? = if same and old then old.flowVersions elseif inputs then {} else nil
		if not same and flowChildren and flowVersions then
			for _, child in node.children do
				if inFlow(child, snapshot) then
					table.insert(flowChildren, child)
					table.insert(
						flowVersions,
						if nextNodes[child] then nextNodes[child].flowVersion or nextNodes[child].version else 0
					)
				end
			end
		end
		-- Size contributions exclude positioned/hidden descendants, but rendered
		-- fragments still use the complete proof above. Never reuse old paint or
		-- omit a new positioned box merely because normal-flow sizes are stable.
		local oldFlowChildren, oldFlowVersions =
			if old then old.flowChildren else nil, if old then old.flowVersions else nil
		local sameFlow = inputs ~= nil
			and old ~= nil
			and old.flowVersion ~= nil
			and old.parent == node.parent
			and old.tag == node.tag
			and old.text == node.text
			and TextSegments.same(old.textAfter, node.textAfter)
			and LayoutStyles.sameIntrinsic(old.style, style)
			and sameFlowPseudo(old.before, before)
			and sameFlowPseudo(old.after, after)
			and sameMap(old.attributes, node.attributes, inputs.attributes)
			and sameMap(old.states, node.states, inputs.states)
			and oldFlowChildren ~= nil
			and oldFlowVersions ~= nil
			and flowChildren ~= nil
			and #oldFlowChildren == #flowChildren
		if sameFlow and flowChildren and flowVersions and oldFlowChildren and oldFlowVersions then
			for i, child in flowChildren do
				if oldFlowChildren[i] ~= child or oldFlowVersions[i] ~= flowVersions[i] then
					sameFlow = false
					break
				end
			end
		end
		local current: Inputs
		if same and old then
			current = old
		else
			cache.version += 1
			current = {
				parent = node.parent,
				tag = node.tag,
				id = node.id,
				className = node.className,
				text = node.text,
				textAfter = TextSegments.copy(node.textAfter),
				attributes = table.clone(node.attributes),
				states = table.clone(node.states),
				style = style,
				before = before,
				after = after,
				children = table.clone(node.children),
				versions = versions,
				version = cache.version,
				flowVersion = if inputs then (if sameFlow then assert(old).flowVersion else cache.version) else nil,
				flowChildren = flowChildren,
				flowVersions = flowVersions,
				count = count,
				entries = if sameFlow then assert(old).entries else {},
				intrinsics = if sameFlow then assert(old).intrinsics else {},
				fragments = {},
				flex = if sameFlow then assert(old).flex else {},
			}
		end
		-- Pending/failure results are deliberately retried on the next scene.
		for i = #current.entries, 1, -1 do
			if current.entries[i].failure or not current.entries[i].result then
				table.remove(current.entries, i)
			end
		end
		nextNodes[node] = current
		entries[node] = current.entries
		intrinsics[node] = current.intrinsics
		-- Bound duplicated fragment ownership in deep/wide trees. Larger
		-- branches still format normally and reuse their smaller descendants.
		if count <= 32 then
			fragments[node] = current.fragments
		end
		return current.version
	end
	for _, node in snapshot.roots do
		visit(node)
	end
	cache.nodes = if snapshot.layoutRevision ~= nil then nextNodes else {}
	return entries, intrinsics, fragments
end

-- The existing flow version and resource epoch own these pure sizing results.
-- They never retain old paint, styles or intrinsic callbacks.
function BlockMeasurements.flex(cache: Cache, node: Types.Node): { FlexLayouts.Entry }?
	local record = if cache.inputs and cache.epoch ~= nil then cache.nodes[node] else nil
	return if record then record.flex else nil
end

function BlockMeasurements.flowVersion(cache: Cache, node: Types.Node): number?
	local record = if cache.inputs and cache.epoch ~= nil then cache.nodes[node] else nil
	return if record then record.flowVersion else nil
end

return BlockMeasurements
