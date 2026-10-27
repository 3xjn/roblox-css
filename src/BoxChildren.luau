--!strict

local Types = require(script.Parent.Types)
local SceneTypes = require(script.Parent.SceneTypes)
local Display = require(script.Parent.Display)
local GeneratedContent = require(script.Parent.GeneratedContent)
local TextSegments = require(script.Parent.TextSegments)

export type Pseudo = (Types.Node, string) -> (Types.Node?, string?)
local BoxChildren = {}

-- Project render children without reparenting logical nodes. Text sequences
-- through contents need the source-preserving inline formatter, not a made-up
-- block or flex wrapper that would alter struts and whitespace boundaries.
function BoxChildren.project(
	node: Types.Node,
	snapshot: SceneTypes.Snapshot,
	pseudo: Pseudo?
): ({ Types.Node }?, string?)
	local special = false
	for _, child in node.children do
		local style = snapshot.styles[child]
		if not style then
			return nil, "missing-box-child-style"
		end
		local display, failure = Display.forNode(style, child)
		if not display then
			return nil, failure
		end
		if display == "contents" or display == "none" then
			special = true
			break
		end
	end
	if not special then
		return node.children, nil
	end
	local result: { Types.Node } = {}
	local active: { [Types.Node]: boolean } = { [node] = true }
	local function appendPseudo(origin: Types.Node, name: string): string?
		local style = if snapshot.pseudoStyle then snapshot.pseudoStyle(origin, name) else nil
		if not style then
			return nil
		end
		local display, displayFailure = Display.resolve(style)
		if not display then
			return displayFailure
		end
		if display == "none" then
			return nil
		end
		local content, failure = GeneratedContent.resolve(style)
		if not content then
			return failure
		end
		if content == "none" or display == "contents" then
			return nil
		end
		if not pseudo then
			return "contents-pseudo-formatting-provider-required"
		end
		local fragment, reason = pseudo(origin, name)
		if reason then
			return reason
		end
		if fragment then
			table.insert(result, fragment)
		end
		return nil
	end
	local append: (Types.Node) -> string?
	append = function(child: Types.Node): string?
		if active[child] then
			return "contents-child-cycle"
		end
		local style = snapshot.styles[child]
		if not style then
			return "missing-box-child-style"
		end
		local display, failure = Display.forNode(style, child)
		if not display then
			return failure
		end
		if display == "none" then
			return nil
		end
		if display ~= "contents" then
			table.insert(result, child)
			return nil
		end
		active[child] = true
		local reason = appendPseudo(child, "before")
		if reason then
			return reason
		end
		if child.text ~= "" or TextSegments.has(child.textAfter) then
			return "contents-text-formatting-provider-required"
		end
		for _, descendant in child.children do
			reason = append(descendant)
			if reason then
				return reason
			end
		end
		reason = appendPseudo(child, "after")
		active[child] = nil
		return reason
	end
	for _, child in node.children do
		local failure = append(child)
		if failure then
			return nil, failure
		end
	end
	return result, nil
end

function BoxChildren.resolve(node: Types.Node, snapshot: SceneTypes.Snapshot): ({ Types.Node }?, string?)
	if snapshot.boxChildren then
		return snapshot.boxChildren(node)
	end
	return BoxChildren.project(node, snapshot)
end

-- Insert anonymous text fragments around the projected element children.
-- The logical child array remains element-only. Custom projections must keep
-- their logical ancestor groups in document order to retain text anchors.
function BoxChildren.withText(
	node: Types.Node,
	children: { Types.Node },
	text: (number, string) -> (Types.Node?, string?)
): ({ Types.Node }?, string?)
	local failure = TextSegments.validate(node.textAfter, #node.children)
	if failure then
		return nil, failure
	end
	local indexes: { [Types.Node]: number } = {}
	for index, child in node.children do
		indexes[child] = index
	end
	local groups: { [number]: { Types.Node } } = {}
	local last = 0
	for _, child in children do
		local cursor: Types.Node? = child
		local seen: { [Types.Node]: boolean } = {}
		while cursor and not indexes[cursor] do
			if seen[cursor] then
				return nil, "ordered-text-projection-cycle"
			end
			seen[cursor] = true
			cursor = cursor.parent
		end
		local index = cursor and indexes[cursor]
		if not index or index < last then
			return nil, "ordered-text-projection-provider-required"
		end
		last = index
		local group = groups[index] or {}
		groups[index] = group
		table.insert(group, child)
	end
	local result: { Types.Node } = {}
	local function appendText(index: number, content: string?): string?
		if content and content ~= "" then
			local fragment, reason = text(index, content)
			if reason then
				return reason
			end
			if fragment then
				table.insert(result, fragment)
			end
		end
		return nil
	end
	local reason = appendText(0, node.text)
	if reason then
		return nil, reason
	end
	for index = 1, #node.children do
		for _, child in groups[index] or {} do
			table.insert(result, child)
		end
		reason = appendText(index, node.textAfter and node.textAfter[index])
		if reason then
			return nil, reason
		end
	end
	return result, nil
end

function BoxChildren.parent(node: Types.Node, snapshot: SceneTypes.Snapshot): (Types.Node?, string?)
	local parent = node.parent
	local visited: { [Types.Node]: boolean } = { [node] = true }
	while parent do
		if visited[parent] then
			return nil, "contents-parent-cycle"
		end
		visited[parent] = true
		local style = snapshot.styles[parent]
		if not style then
			return nil, "missing-box-parent-style"
		end
		local display, failure = Display.forNode(style, parent, snapshot.roots[1] == parent)
		if not display then
			return nil, failure
		end
		if display ~= "contents" then
			return parent, nil
		end
		parent = parent.parent
	end
	return nil, nil
end

return BoxChildren
