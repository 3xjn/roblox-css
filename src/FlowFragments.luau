--!strict

local Types = require(script.Parent.Types)
local SceneTypes = require(script.Parent.SceneTypes)
local FormattingFragments = require(script.Parent.FormattingFragments)
local LayoutStyles = require(script.Parent.LayoutStyles)
local Display = require(script.Parent.Display)
local BoxChildren = require(script.Parent.BoxChildren)
local NativeImage = require(script.Parent.NativeImage)

export type State = {
	version: number,
	entry: FormattingFragments.Entry,
	styles: { [Types.Node]: Types.ComputedStyle },
	parents: { [Types.Node]: Types.ComputedStyle },
	pseudos: { [Types.Node]: { source: Types.ComputedStyle, style: Types.ComputedStyle } },
}
local FlowFragments = {}

local function retainPseudos(
	styles: { [Types.Node]: Types.ComputedStyle },
	snapshot: SceneTypes.Snapshot,
	previous: { [Types.Node]: { source: Types.ComputedStyle, style: Types.ComputedStyle } }?
): { [Types.Node]: { source: Types.ComputedStyle, style: Types.ComputedStyle } }
	local result = {}
	for node, style in styles do
		if (node.tag == "#before" or node.tag == "#after") and node.parent and snapshot.pseudoStyle then
			local source = snapshot.pseudoStyle(node.parent, string.sub(node.tag, 2))
			if source then
				local old = previous and previous[node]
				local formatting = if old and old.source == source then old.style else style
				styles[node] = formatting
				snapshot.styles[node] = formatting
				result[node] = { source = source, style = formatting }
			end
		end
	end
	return result
end

-- The built-in formatter's transitive flow version certifies used geometry.
-- Keep one bounded, owned normal-flow fragment; positioned descendants are
-- deliberately absent and must be collected and formatted from current inputs.
function FlowFragments.capture(
	version: number,
	layout: FormattingFragments.Layout,
	plan: SceneTypes.Plan,
	rank: number,
	snapshot: SceneTypes.Snapshot,
	immutable: boolean?
): State?
	local keys: { SceneTypes.Key } = {}
	local privateKeys: { Types.Node } = {}
	local owners: { [Types.Node]: Types.Node } = {}
	for key, box in plan.boxes do
		if box.outOfFlow then
			return nil -- Replaced images and nested inline formatting keep their ordinary path.
		end
		table.insert(keys, key)
		if plan.styles and plan.styles[box.node] then
			table.insert(privateKeys, box.node)
			owners[box.node] = box.owner
		end
	end
	local entries: { FormattingFragments.Entry } = {}
	FormattingFragments.capture(entries, {
		parent = nil,
		width = 0,
		direction = "ltr",
	}, layout, keys, plan, 0, rank, {}, owners, privateKeys, immutable)
	local entry = entries[1]
	if not entry then
		return nil
	end
	local parents: { [Types.Node]: Types.ComputedStyle } = {}
	for node in entry.styles do
		if node.parent and snapshot.styles[node.parent] then
			parents[node.parent] = snapshot.styles[node.parent]
		end
	end
	return {
		version = version,
		entry = entry,
		styles = entry.styles,
		parents = parents,
		pseudos = retainPseudos(plan.styles or {}, snapshot, nil),
	}
end

function FlowFragments.restore(
	state: State,
	version: number,
	plan: SceneTypes.Plan,
	snapshot: SceneTypes.Snapshot,
	imageSource: ((Types.Node) -> (NativeImage.Data?, string?))?,
	pseudo: BoxChildren.Pseudo,
	owners: { [Types.Node]: Types.Node },
	positioned: { FormattingFragments.Positioned },
	immutable: boolean?
): (FormattingFragments.Layout?, number?, string?)
	if state.version ~= version then
		return nil, nil, nil
	end
	local entry = table.clone(state.entry)
	local private: { [Types.Node]: Types.ComputedStyle } = {}
	local parents: { [Types.Node]: Types.ComputedStyle } = {}
	for node, old in state.styles do
		local style: Types.ComputedStyle? = nil
		if node.tag == "#flex-line" then
			style = old
		elseif node.tag == "#text" and node.parent and snapshot.anonymousStyle then
			local parent = snapshot.styles[node.parent]
			parents[node.parent] = parent
			if parent and parent == state.parents[node.parent] then
				style = old
			else
				style = snapshot.anonymousStyle(node.parent)
				if style then
					style = table.clone(style)
					style.properties = table.clone(style.properties)
					style.properties.display = { { kind = "word", value = "block" } }
				end
			end
		end
		if not style or not LayoutStyles.sameIntrinsic(old, style) then
			return nil, nil, nil
		end
		private[node] = style
	end
	entry.styles = private
	local layout, rank, failure =
		FormattingFragments.restore(entry, plan, 0, imageSource, snapshot, owners, {}, immutable)
	if not layout then
		return nil, nil, failure
	end
	-- Editor values are presentation data, independent of intrinsic sizing.
	for _, box in plan.boxes do
		if box.kind == "text-input" then
			local node = box.node
			local kind = node.attributes.type
			if #node.children > 0 or (kind and string.lower(kind) ~= "text" and string.lower(kind) ~= "search") then
				return nil, nil, nil
			end
			box.editor = {
				value = node.attributes.value,
				defaultValue = node.attributes["default-value"],
				placeholder = node.attributes.placeholder,
				multiline = node.tag == "textarea",
			}
		elseif box.kind == "image" and (#box.node.children > 0 or box.node.text ~= "") then
			return nil, nil, nil
		end
	end
	local function absolute(node: Types.Node): boolean
		local style = snapshot.styles[node]
		local tokens = style and style.properties.position
		return tokens ~= nil
			and #tokens == 1
			and tokens[1].kind == "word"
			and string.lower(tokens[1].value) == "absolute"
	end
	local collect: (Types.Node, Types.Node?) -> (boolean, string?)
	collect = function(node: Types.Node, parent: Types.Node?): (boolean, string?)
		local style = snapshot.styles[node]
		if not style then
			return false, nil
		end
		local display = Display.forNode(style, node, snapshot.roots[1] == node)
		if display == "none" then
			return true, nil
		elseif absolute(node) then
			table.insert(positioned, { node = node, parent = parent })
			return true, nil
		end
		local box = plan.boxes[node]
		if not box then
			return false, nil -- Embedded inline shapes retain full formatting.
		end
		local before, reason = pseudo(node, "before")
		if reason then
			return false, reason
		elseif before then
			table.insert(positioned, { node = before, parent = node })
		end
		local after, afterFailure = pseudo(node, "after")
		if afterFailure then
			return false, afterFailure
		end
		local children, childFailure = BoxChildren.resolve(node, snapshot)
		if not children then
			return false, childFailure
		end
		local flex = (display == "flex" or display == "inline-flex")
			and box.kind ~= "image"
			and box.kind ~= "text-input"
		if flex then
			for _, child in children do
				if absolute(child) then
					local valid, failure = collect(child, node)
					if not valid then
						return false, failure
					end
				end
			end
		end
		for _, child in children do
			if not flex or not absolute(child) then
				local valid, failure = collect(child, node)
				if not valid then
					return false, failure
				end
			end
		end
		if after then
			table.insert(positioned, { node = after, parent = node })
		end
		return true, nil
	end
	local valid, reason = collect(entry.node, nil)
	if valid then
		state.styles, state.parents = private, parents
		state.pseudos = retainPseudos(assert(plan.styles), snapshot, state.pseudos)
	end
	return if valid then layout else nil, if valid then rank else nil, reason
end

return FlowFragments
