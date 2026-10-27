--!strict

local Types = require(script.Parent.Types)
local TextSegments = require(script.Parent.TextSegments)
local SceneTypes = require(script.Parent.SceneTypes)
local GeneratedContent = require(script.Parent.GeneratedContent)
local SceneAnimations = require(script.Parent.SceneAnimations)
local LayoutStyles = require(script.Parent.LayoutStyles)

type NodeState = {
	parent: Types.Node?,
	tag: string,
	nativeControl: ("auto" | "button")?,
	id: string?,
	className: string,
	text: string,
	textAfter: TextSegments.After?,
	attributes: { [string]: string },
	states: { [string]: boolean },
	disabled: boolean,
	children: { Types.Node },
}
type State = {
	plan: SceneTypes.Plan,
	presentation: {},
	geometry: {},
	layoutRevision: number,
	viewport: Vector2,
	initialFontSize: number?,
	roots: { Types.Node },
	nodes: { [Types.Node]: NodeState },
	styles: { [Types.Node]: Types.ComputedStyle },
	pseudos: { [Types.Node]: { [string]: Types.ComputedStyle } },
	placeholders: { [Types.Node]: { style: Types.ComputedStyle? } },
	animations: { [Types.Node]: SceneAnimations.Data }?,
	transformContexts: { [Types.Node]: boolean },
}

local function sameArray<T>(a: { T }, b: { T }): boolean
	if #a ~= #b then
		return false
	end
	for i, value in a do
		if b[i] ~= value then
			return false
		end
	end
	return true
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
	for key, value in a do
		if b[key] ~= value then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local sameLayout = LayoutStyles.same

-- Animation programs are immutable, acyclic value snapshots. Native clocks own
-- elapsed time; a repeated style commit must not restart unchanged programs.
-- Compare the freshly resolved values too: conditional keyframes and lifecycle
-- flags can change while the ordinary computed style retains its identity.
local function sameAnimationValue(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not sameAnimationValue(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function sameAnimations(
	a: { [Types.Node]: SceneAnimations.Data }?,
	b: { [Types.Node]: SceneAnimations.Data }?
): boolean
	if a == b then
		return true
	end
	if not a or not b then
		return false
	end
	for node, data in a do
		local other = b[node]
		if not other or data.style ~= other.style or not sameAnimationValue(data, other) then
			return false
		end
	end
	for node in b do
		if not a[node] then
			return false
		end
	end
	return true
end

local function pseudos(snapshot: SceneTypes.Snapshot, node: Types.Node): { [string]: Types.ComputedStyle }
	local result = {}
	if snapshot.pseudoStyle then
		for _, name in { "before", "after" } do
			local style = snapshot.pseudoStyle(node, name)
			if style then
				result[name] = style
			end
		end
	end
	return result
end

local function placeholderStyles(
	plan: SceneTypes.Plan,
	snapshot: SceneTypes.Snapshot
): { [Types.Node]: { style: Types.ComputedStyle? } }
	local result: { [Types.Node]: { style: Types.ComputedStyle? } } = {}
	for _, box in plan.boxes do
		if box.kind == "text-input" and box.editor and box.editor.placeholder and box.editor.placeholder ~= "" then
			local node = box.node
			if not result[node] then
				result[node] =
					{ style = if snapshot.pseudoStyle then snapshot.pseudoStyle(node, "placeholder") else nil }
			end
		end
	end
	return result
end

-- A transform interval affects formatting only while it keeps a target `none`
-- as a containing block. Other active/settled interval and rotation changes are
-- paint/preparation inputs; comparing those would reformat on every settlement.
local function transformContexts(
	snapshot: SceneTypes.Snapshot,
	privateStyles: { [Types.Node]: Types.ComputedStyle }?
): { [Types.Node]: boolean }
	local result = {}
	if snapshot.transformTransitions then
		for node, requirement in snapshot.transformTransitions do
			local style = snapshot.styles[node] or (privateStyles and privateStyles[node])
			local tokens = style and style.properties.transform
			if
				requirement.context
				and (not tokens or (#tokens == 1 and tokens[1].kind == "word" and tokens[1].value == "none"))
			then
				result[node] = true
			end
		end
	end
	return result
end

local function capture(plan: SceneTypes.Plan, snapshot: SceneTypes.Snapshot): State
	local nodes = {}
	local pseudoStyles = {}
	local styles = {}
	for node, style in snapshot.styles do
		if plan.styles and plan.styles[node] then
			continue -- Generated boxes are restored from their originating element below.
		end
		styles[node] = style
		nodes[node] = {
			parent = node.parent,
			tag = node.tag,
			nativeControl = node.nativeControl,
			id = node.id,
			className = node.className,
			text = node.text,
			textAfter = TextSegments.copy(node.textAfter),
			attributes = table.clone(node.attributes),
			states = table.clone(node.states),
			disabled = node.states.disabled == true,
			children = table.clone(node.children),
		}
		pseudoStyles[node] = pseudos(snapshot, node)
	end
	return {
		plan = plan,
		presentation = {},
		geometry = {},
		layoutRevision = assert(snapshot.layoutRevision),
		viewport = snapshot.viewport,
		initialFontSize = snapshot.initialFontSize,
		roots = table.clone(snapshot.roots),
		nodes = nodes,
		styles = styles,
		pseudos = pseudoStyles,
		placeholders = placeholderStyles(plan, snapshot),
		animations = snapshot.animations,
		transformContexts = transformContexts(snapshot, plan.styles),
	}
end

export type Inputs = { attributes: { [string]: boolean }, states: { [string]: boolean }, ignoreRangeValue: boolean? }

local function sameAttributes(before: NodeState, node: Types.Node, inputs: Inputs?): boolean
	if not inputs or not inputs.ignoreRangeValue or node.tag ~= "input"
		or string.lower(node.attributes.type or "") ~= "range" then
		return sameMap(before.attributes, node.attributes, if inputs then inputs.attributes else nil)
	end
	for name in inputs.attributes do
		if name ~= "value" and before.attributes[name] ~= node.attributes[name] then
			return false
		end
	end
	return true
end

local function reuse(previous: State, snapshot: SceneTypes.Snapshot, inputs: Inputs?): SceneTypes.Plan?
	if
		snapshot.layoutRevision ~= previous.layoutRevision
		or snapshot.viewport ~= previous.viewport
		or snapshot.initialFontSize ~= previous.initialFontSize
		or not sameArray(previous.roots, snapshot.roots)
	then
		return nil
	end
	local nextPseudos = {}
	local unchanged = true
	for node, before in previous.nodes do
		if
			not snapshot.styles[node]
			or node.parent ~= before.parent
			or node.tag ~= before.tag
			or node.id ~= before.id
			or node.className ~= before.className
			or node.text ~= before.text
			or not TextSegments.same(before.textAfter, node.textAfter)
			or not sameArray(before.children, node.children)
			or not sameAttributes(before, node, inputs)
			or not sameMap(before.states, node.states, if inputs then inputs.states else nil)
			or not sameLayout(previous.styles[node], snapshot.styles[node])
		then
			return nil
		end
		-- Native eligibility also reads disabled state independently of CSS.
		-- Provider state dependencies were checked above; other interaction-only
		-- inputs need no native commit when their computed styles are unchanged.
		unchanged = unchanged
			and previous.styles[node] == snapshot.styles[node]
			and before.disabled == (node.states.disabled == true)
			and before.nativeControl == node.nativeControl
		local current = pseudos(snapshot, node)
		for _, name in { "before", "after" } do
			if not sameLayout(previous.pseudos[node][name], current[name]) then
				return nil
			end
		end
		nextPseudos[node] = current
	end
	for node in snapshot.styles do
		if not previous.nodes[node] then
			return nil
		end
	end
	local private = {}
	for node, old in previous.plan.styles or {} do
		local parent = node.parent
		local current: Types.ComputedStyle? = nil
		if node.tag == "#flex-line" then
			current = old
		elseif parent and node.tag == "#text" and snapshot.anonymousStyle then
			if previous.styles[parent] == snapshot.styles[parent] then
				current = old
			else
				current = snapshot.anonymousStyle(parent)
				if current then
					current = table.clone(current)
					current.properties = table.clone(current.properties)
					current.properties.display = { { kind = "word", value = "block" } }
				end
			end
		elseif parent and (node.tag == "#before" or node.tag == "#after") then
			local name = string.sub(node.tag, 2)
			local source = nextPseudos[parent] and nextPseudos[parent][name]
			if source and GeneratedContent.resolve(source) == "empty" then
				if previous.pseudos[parent] and previous.pseudos[parent][name] == source then
					current = old
				else
					current = table.clone(source)
					current.properties = table.clone(source.properties)
					current.properties.content = { { kind = "word", value = "normal" } }
				end
			end
		end
		if not current or not sameLayout(old, current) then
			return nil
		end
		if parent and (node.tag == "#before" or node.tag == "#after") then
			if snapshot.animation then
				local _, why = snapshot.animation(node, current, parent, string.sub(node.tag, 2))
				if why then
					return nil -- The formatter reports the failure through its ordinary path.
				end
			end
			if snapshot.transformTransition and snapshot.transformTransitions then
				local requirement, why = snapshot.transformTransition(node, current)
				if why then
					return nil
				end
				snapshot.transformTransitions[node] = requirement
			end
		end
		unchanged = unchanged and current == old
		private[node] = current
	end
	if
		not sameAnimations(previous.animations, snapshot.animations)
		or not sameAnimationValue(previous.transformContexts, transformContexts(snapshot, private))
	then
		return nil
	end
	local plan = table.clone(previous.plan)
	plan.styles = private
	local placeholders = placeholderStyles(plan, snapshot)
	for node, before in previous.placeholders do
		local current = placeholders[node]
		unchanged = unchanged and current ~= nil and before.style == current.style
	end
	for node in placeholders do
		unchanged = unchanged and previous.placeholders[node] ~= nil
	end
	if not unchanged then
		previous.presentation = {}
	end
	for node, before in previous.nodes do
		before.disabled = node.states.disabled == true
		before.nativeControl = node.nativeControl
	end
	previous.placeholders = placeholders
	previous.animations = snapshot.animations
	previous.plan, previous.styles, previous.pseudos = plan, table.clone(snapshot.styles), nextPseudos
	return plan
end

local SceneCache = {}

-- Only the default host supplies the epoch: font/measurement/resource and
-- native geometry changes advance it; stable style commits do not. Omitted
-- epochs keep ordinary/custom providers uncached.
function SceneCache.create(
	provider: SceneTypes.Provider,
	inputs: Inputs?
): (SceneTypes.Provider, () -> (), () -> ({}?, {}?))
	local dependencies = if inputs
		then { attributes = table.clone(inputs.attributes), states = table.clone(inputs.states), ignoreRangeValue = inputs.ignoreRangeValue }
		else nil
	local previous: State? = nil
	local function resolve(snapshot: SceneTypes.Snapshot): (SceneTypes.Plan?, string?)
		if previous and snapshot.layoutRevision ~= nil then
			local plan = reuse(previous, snapshot, dependencies)
			if plan then
				return plan, nil
			end
		end
		local plan, failure = provider(snapshot)
		previous = if plan and not failure and snapshot.layoutRevision ~= nil then capture(plan, snapshot) else nil
		return plan, failure
	end
	return resolve,
		function()
			previous = nil
		end,
		function()
			return if previous then previous.presentation else nil, if previous then previous.geometry else nil
		end
end

return SceneCache
