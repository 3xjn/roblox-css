--!strict

local Types = require(script.Parent.Types)
local SceneDependencies = {}

-- A path certifies the complete style/parent context, including ancestors
-- that did not themselves produce a native box. Identity changes propagate
-- through descendants; equal values never substitute for style identity.
export type Path = {
	read node: Types.Node,
	read style: Types.ComputedStyle?,
	read parent: Types.Node?,
	read ancestor: Path?,
}
export type Paths = { [Types.Node]: Path }
export type Reader = (Types.Node) -> Path?

-- One reader belongs to one stable preparation snapshot. The default host's
-- revision guard cancels that pass if the logical graph changes while yielded.
-- Only current paths survive in the returned map; no history is accumulated.
function SceneDependencies.create(styles: { [Types.Node]: Types.ComputedStyle }, previous: Paths?): (Reader, Paths)
	local paths: Paths = {}
	local active: { [Types.Node]: boolean } = {}
	local invalid: { [Types.Node]: boolean } = {}
	local read: Reader
	read = function(node: Types.Node): Path?
		if paths[node] then
			return paths[node]
		end
		if invalid[node] or active[node] then
			return nil -- Cycles cannot certify reuse; normal preparation diagnoses them.
		end
		active[node] = true
		local parent = node.parent
		local ancestor = if parent then read(parent) else nil
		active[node] = nil
		if parent and ancestor == nil then
			invalid[node] = true
			return nil
		end
		local old = if previous then previous[node] else nil
		local path: Path
		if old and old.style == styles[node] and old.parent == parent and old.ancestor == ancestor then
			path = old
		else
			path = { node = node, style = styles[node], parent = parent, ancestor = ancestor }
		end
		paths[node] = path
		return path
	end
	return read, paths
end

return SceneDependencies
