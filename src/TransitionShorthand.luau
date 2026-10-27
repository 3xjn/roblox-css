--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local Easing = require(script.Parent.Easing)
type Token = Types.ValueToken
local TransitionShorthand = {}
TransitionShorthand.targets = {
	"transition-property",
	"transition-duration",
	"transition-timing-function",
	"transition-delay",
	"transition-behavior",
}
local easingWords = {
	linear = true,
	ease = true,
	["ease-in"] = true,
	["ease-out"] = true,
	["ease-in-out"] = true,
	["step-start"] = true,
	["step-end"] = true,
}
local easingFunctions = { ["cubic-bezier"] = true, steps = true, linear = true }
local mathFunctions = { calc = true, min = true, max = true, clamp = true }
local forbidden =
	{ initial = true, inherit = true, unset = true, revert = true, ["revert-layer"] = true, default = true }
local function word(value: string): Token
	return { kind = "word", value = value }
end
local function zero(): Token
	return { kind = "dimension", value = "0", unit = "s" }
end

-- Tokens have already been parsed by CSS-tree and substituted by Variables.
-- Expansion resets all longhands, including omitted components, before the
-- ordinary cascade compares shorthand and explicit longhand declarations.
function TransitionShorthand.resolve(target: string, parts: { Token }): ({ Token }?, string?)
	if not table.find(TransitionShorthand.targets, target) then
		return nil, "unknown-transition-shorthand-target"
	end
	local groups: { { Token } } = { {} }
	for _, token in parts do
		if token.kind == "div" and token.value == "," then
			table.insert(groups, {} :: { Token })
		else
			table.insert(groups[#groups], token)
		end
	end
	local output: { Token } = {}
	for index, group in groups do
		if #group == 0 then
			return nil, "empty-transition-shorthand-item"
		end
		local property: Token? = nil
		local duration: Token? = nil
		local delay: Token? = nil
		local easing: Token? = nil
		local behavior: Token? = nil
		for _, token in group do
			local name = string.lower(token.value)
			if token.kind == "dimension" or (token.kind == "function" and mathFunctions[name]) then
				local measured, failure = Measurements.resolve({ token }, {})
				if not measured then
					return nil, "transition-time-computation-pending:" .. (failure or "unknown")
				end
				if measured.dimension ~= "time" or measured.percentage ~= nil then
					return nil, "invalid-transition-time-type"
				end
				if not duration then
					if measured.value < 0 and token.kind ~= "function" then
						return nil, "negative-transition-duration"
					end
					-- A range-limited math result is clamped at computed-value time.
					duration = if measured.value < 0 then zero() else token
				elseif not delay then
					delay = token
				else
					return nil, "too-many-transition-times"
				end
			elseif (token.kind == "word" and easingWords[name]) and not easing then
				local parsed, failure = Easing.parse(token)
				if not parsed then
					return nil, failure
				end
				easing = token
			elseif token.kind == "function" and easingFunctions[name] then
				if easing then
					return nil, "duplicate-transition-easing"
				end
				local parsed, failure = Easing.parse(token)
				if not parsed then
					return nil, failure
				end
				easing = token
			elseif token.kind == "word" and (name == "normal" or name == "allow-discrete") and not behavior then
				behavior = token
			elseif token.kind == "word" and not property and not forbidden[name] then
				if token.value:find("\\") then
					return nil, "transition-shorthand-provider-required"
				end
				property = token
			elseif token.kind == "function" then
				return nil, "transition-shorthand-provider-required"
			else
				return nil, "invalid-transition-shorthand-item"
			end
		end
		if property and string.lower(property.value) == "none" and #groups ~= 1 then
			return nil, "none-in-transition-list"
		end
		local values: { [string]: Token } = {
			["transition-property"] = property or word("all"),
			["transition-duration"] = duration or zero(),
			["transition-delay"] = delay or zero(),
			["transition-timing-function"] = easing or word("ease"),
			["transition-behavior"] = behavior or word("normal"),
		}
		if index > 1 then
			table.insert(output, { kind = "div", value = "," })
		end
		table.insert(output, values[target])
	end
	return output, nil
end
return TransitionShorthand
