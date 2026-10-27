--!strict

local Types = require(script.Parent.Types)
local GridLine = require(script.Parent.GridLine)
type Token = Types.ValueToken
local GridShorthand = {}
GridShorthand.targets = {
	["grid-row"] = { "grid-row-start", "grid-row-end" },
	["grid-column"] = { "grid-column-start", "grid-column-end" },
	["grid-area"] = { "grid-row-start", "grid-column-start", "grid-row-end", "grid-column-end" },
}

local function automatic(): { Token }
	return { { kind = "word", value = "auto" } }
end

-- Resolve the complete shorthand before selecting a target. An invalid later
-- component must not leave an earlier longhand partially applied.
function GridShorthand.resolve(property: string, target: string, tokens: { Token }): ({ Token }?, string?)
	local targets = GridShorthand.targets[property]
	local selected = if targets then table.find(targets, target) else nil
	if not selected then
		return nil, "unknown-grid-shorthand-target"
	end
	local groups: { { Token } } = { {} }
	for _, token in tokens do
		if token.kind == "space" or token.kind == "comment" then
			continue
		elseif token.kind == "operator" and token.value == "/" then
			table.insert(groups, {} :: { Token })
		else
			table.insert(groups[#groups], token)
		end
	end
	if #groups > #targets then
		return nil, "too-many-grid-shorthand-components"
	end
	local lines: { GridLine.Line } = {}
	for i, group in groups do
		local line, failure = GridLine.parse(group)
		if not line then
			return nil, failure
		end
		lines[i] = line
	end
	local function omitted(index: number): { Token }
		local line = lines[index]
		return if line.kind == "line" and line.name ~= nil and line.index == nil then groups[index] else automatic()
	end
	if property == "grid-area" then
		groups[2] = groups[2] or omitted(1)
		-- A synthesized column start can only be auto or the same single name.
		lines[2] = lines[2]
			or (if lines[1].kind == "line" and lines[1].index == nil then lines[1] else { kind = "auto" })
		groups[3] = groups[3] or omitted(1)
		groups[4] = groups[4] or omitted(2)
	else
		groups[2] = groups[2] or omitted(1)
	end
	return groups[selected], nil
end

return GridShorthand
