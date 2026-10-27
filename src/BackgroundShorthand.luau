--!strict

local Types = require(script.Parent.Types)
local Colors = require(script.Parent.Colors)
type Token = Types.ValueToken

local BackgroundShorthand = {}
BackgroundShorthand.targets = {
	"background-image",
	"background-position",
	"background-size",
	"background-repeat",
	"background-origin",
	"background-clip",
	"background-attachment",
	"background-color",
}
local boxes = { ["border-box"] = true, ["padding-box"] = true, ["content-box"] = true }
local attachments = { scroll = true, fixed = true, ["local"] = true }
local repeats = { ["repeat"] = true, ["no-repeat"] = true, round = true, space = true }
local repeatAliases = { ["repeat-x"] = true, ["repeat-y"] = true }

-- This expansion shares the normal cascade/substitution path. Unsupported
-- components must stay pending across *all* targets, not erase a valid layer.
function BackgroundShorthand.resolve(target: string, parts: { Token }): ({ Token }?, string?)
	if #parts == 0 then
		return nil, "empty-background-shorthand"
	end
	local values: { [string]: { Token } } = {}
	local visual: { Token } = {}
	local repeating: { Token } = {}
	local lastRepeat = 0
	for index, token in parts do
		local name = string.lower(token.value)
		if token.kind == "word" and boxes[name] then
			if #visual == 2 then
				return nil, "too-many-background-boxes"
			end
			table.insert(visual, token)
		elseif token.kind == "word" and attachments[name] then
			if values["background-attachment"] then
				return nil, "duplicate-background-attachment"
			end
			values["background-attachment"] = { token }
		elseif token.kind == "word" and (repeats[name] or repeatAliases[name]) then
			if #repeating > 0 and lastRepeat ~= index - 1 then
				return nil, "noncontiguous-background-repeat"
			end
			if
				#repeating == 2
				or (#repeating > 0 and (repeatAliases[name] or repeatAliases[string.lower(repeating[1].value)]))
			then
				return nil, "invalid-background-repeat-combination"
			end
			table.insert(repeating, token)
			lastRepeat = index
		elseif token.kind == "word" and name == "none" then
			if values["background-image"] then
				return nil, "duplicate-background-image"
			end
			values["background-image"] = { token }
		elseif
			token.color
			or (token.kind == "word" and name == "currentcolor")
			or token.syntaxType == "color"
			or (token.kind == "function" and Colors.isColorFunction(name))
		then
			if values["background-color"] then
				return nil, "duplicate-background-color"
			end
			values["background-color"] = { token }
		else
			return nil, "background-shorthand-provider-required"
		end
	end
	if #visual > 0 then
		values["background-origin"] = { visual[1] }
		values["background-clip"] = { visual[2] or visual[1] }
	end
	if #repeating > 0 then
		values["background-repeat"] = repeating
	end
	if not table.find(BackgroundShorthand.targets, target) then
		return nil, "unknown-background-shorthand-target"
	end
	return values[target] or { { kind = "word", value = "initial" } }, nil
end

return BackgroundShorthand
