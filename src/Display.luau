--!strict

local Types = require(script.Parent.Types)
local Display = {}
local innerValues = { flow = true, ["flow-root"] = true, flex = true, grid = true, table = true, ruby = true }
local unboxToNone: { [string]: boolean } = {
	br = true,
	wbr = true,
	meter = true,
	progress = true,
	canvas = true,
	embed = true,
	object = true,
	audio = true,
	iframe = true,
	img = true,
	video = true,
	frame = true,
	frameset = true,
	input = true,
	textarea = true,
	select = true,
	svg = true,
	math = true,
}
local legacy = {
	block = { "block", "flow" },
	inline = { "inline", "flow" },
	["inline-block"] = { "inline", "flow-root" },
	["flow-root"] = { "block", "flow-root" },
	flow = { "block", "flow" },
	flex = { "block", "flex" },
	["inline-flex"] = { "inline", "flex" },
	grid = { "block", "grid" },
	["inline-grid"] = { "inline", "grid" },
	table = { "block", "table" },
	["inline-table"] = { "inline", "table" },
}
local tableRoles: { [string]: boolean } = {
	["table-header-group"] = true, ["table-row-group"] = true,
	["table-footer-group"] = true,
	["table-row"] = true, ["table-cell"] = true, ["table-caption"] = true,
}

-- The formatter currently uses block flow for table sections and flex flow
-- for rows. Keep the computed role intact for callers that need it.
function Display.format(role: string): string
	if role == "table-row" then return "flex" end
	if role == "table" or role == "inline-table" or tableRoles[role] then return "block" end
	return role
end

-- Normalize supported outer/inner roles without creating a formatting box or
-- changing computed style. A canonical name is not a renderer capability claim.
function Display.resolve(style: Types.ComputedStyle, blockify: boolean?): (string?, string?)
	if style.unresolved.display then
		return nil, `display:{style.unresolved.display}`
	end
	local words: { string } = {}
	for _, token in style.properties.display or { { kind = "word", value = "inline" } } do
		if token.kind == "space" or token.kind == "comment" then
			continue
		elseif token.kind ~= "word" then
			return nil, "display-syntax-provider-required"
		end
		table.insert(words, string.lower(token.value))
	end
	if #words == 1 and (words[1] == "none" or words[1] == "contents") then
		return words[1], nil
	end
	if #words == 1 and tableRoles[words[1]] then
		return words[1], nil
	end
	local outer: string? = nil
	local inner: string? = nil
	if #words == 1 then
		local pair = legacy[words[1]]
		if not pair then
			return nil, `display-role-provider-required:{words[1]}`
		end
		outer, inner = pair[1], pair[2]
	elseif #words == 2 then
		for _, word in words do
			if (word == "block" or word == "inline") and not outer then
				outer = word
			elseif innerValues[word] and not inner then
				inner = word
			else
				return nil, "display-role-combination-provider-required"
			end
		end
		if not outer or not inner then
			return nil, "display-role-combination-provider-required"
		end
	else
		return nil, "display-role-combination-provider-required"
	end
	if blockify then
		outer = "block"
	end
	if inner == "flow" then
		return outer, nil
	elseif inner == "flow-root" then
		return if outer == "inline" then "inline-block" else "flow-root", nil
	elseif inner == "ruby" then
		-- Ruby blockification has additional inner-role rules; no guessed map.
		return nil, "ruby-formatting-provider-required"
	end
	return if outer == "inline" then `inline-{inner}` else inner, nil
end

-- Box generation is separate from logical selectors and inheritance.
function Display.forNode(style: Types.ComputedStyle, node: Types.Node, root: boolean?): (string?, string?)
	if node.tag == "input" and string.lower(node.attributes.type or "") == "hidden" then
		return "none", nil
	end
	local value, failure = Display.resolve(style)
	if value == "contents" then
		if unboxToNone[node.tag] then
			return "none", nil
		elseif root then
			return "block", nil
		end
	end
	return value, failure
end

return Display
