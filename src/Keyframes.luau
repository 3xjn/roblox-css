--!strict

local Types = require(script.Parent.Types)
local Shorthands = require(script.Parent.Shorthands)
local Keyframes = {}

-- Selection belongs to the enclosing sheet's layers and conditions. Duplicate
-- offsets within one definition cascade in source order; definitions never merge.
function Keyframes.prepare(
	node: Types.AtRule,
	layer: { number },
	conditions: { Types.Condition },
	metadata: { [string]: Types.PropertyMetadata },
	diagnose: Types.Diagnose
): Types.PreparedKeyframes?
	local definition = node.keyframes
	if not definition then
		diagnose("keyframes-metadata-required", `Regenerate @keyframes {node.params}`, node.source)
		return nil
	elseif definition.status == "invalid" then
		diagnose("invalid-keyframes", definition.reason, node.source)
		return nil
	end
	local offsets: { [number]: { Types.Declaration } } = {}
	local declarationOrder = 0
	for _, child in node.children or {} do
		if child.kind ~= "keyframe-step" then
			diagnose("invalid-keyframes-child", child.kind, child.source)
			continue
		end
		if not child.positions then
			diagnose("keyframe-offset-metadata-required", "Regenerate keyframe selectors", child.source)
			continue
		end
		local valid = #child.positions > 0
		for _, offset in child.positions do
			if offset ~= offset or offset < 0 or offset > 1 then
				valid = false
			end
		end
		if not valid then
			diagnose("invalid-keyframe-selector", table.concat(child.offsets, ","), child.source)
			continue
		end
		local declarations: { Types.Declaration } = {}
		for _, entry in child.children do
			declarationOrder += 1
			if entry.kind ~= "declaration" then
				diagnose("invalid-keyframe-child", entry.kind, entry.source)
			elseif not entry.important and entry.validity ~= "invalid" then
				if entry.property == "animation" or (entry.property:sub(1,10) == "animation-"
					and entry.property ~= "animation-timing-function" and entry.property ~= "animation-composition") then
					continue
				end
				for _, expanded in Shorthands.expand(entry, metadata) do
					local copy = table.clone(expanded)
					copy.cascadeOrder = declarationOrder
					table.insert(declarations, copy)
				end
			end
		end
		local seen: { [number]: boolean } = {}
		for _, offset in child.positions do
			if seen[offset] then
				continue
			end
			seen[offset] = true
			local entries = offsets[offset] or {}
			offsets[offset] = entries
			for _, entry in declarations do
				table.insert(entries, entry)
			end
		end
	end
	local frames: { Types.PreparedKeyframe } = {}
	for offset, declarations in offsets do
		table.insert(frames, { offset = offset, declarations = declarations })
	end
	table.sort(frames, function(a: Types.PreparedKeyframe, b: Types.PreparedKeyframe)
		return a.offset < b.offset
	end)
	return {
		name = definition.name,
		frames = frames,
		layer = layer,
		conditions = table.clone(conditions),
		source = node.source,
	}
end

-- Public lookup returns independent data; native animation preparation can keep
-- the private prepared definition without giving callers mutation ownership.
function Keyframes.copy(definition: Types.PreparedKeyframes): Types.PreparedKeyframes
	local function clone(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local result = {}
		for key, child in next, value do
			result[key] = clone(child)
		end
		return result
	end
	return clone(definition)
end

return Keyframes
