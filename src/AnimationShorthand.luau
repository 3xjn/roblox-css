--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local Easing = require(script.Parent.Easing)
type Token = Types.ValueToken

local AnimationShorthand = {}
AnimationShorthand.targets = {
	"animation-name",
	"animation-duration",
	"animation-timing-function",
	"animation-delay",
	"animation-iteration-count",
	"animation-direction",
	"animation-fill-mode",
	"animation-play-state",
	"animation-timeline",
	"animation-range-start",
	"animation-range-end",
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
local directions = { normal = true, reverse = true, alternate = true, ["alternate-reverse"] = true }
local fills = { none = true, forwards = true, backwards = true, both = true }
local states = { running = true, paused = true }
local forbidden =
	{ initial = true, inherit = true, unset = true, revert = true, ["revert-layer"] = true, default = true }
local function word(value: string): Token
	return { kind = "word", value = value }
end
local function number(value: string): Token
	return { kind = "number", value = value }
end
local function zero(): Token
	return { kind = "dimension", value = "0", unit = "s" }
end

-- Variables substitutes first; the ordinary cascade owns longhand priority,
-- CSS-wide keywords and rollback. This module only resolves shorthand grammar.
function AnimationShorthand.resolve(target: string, parts: { Token }): ({ Token }?, string?)
	if not table.find(AnimationShorthand.targets, target) then
		return nil, "unknown-animation-shorthand-target"
	end
	local groups: { { Token } } = { {} }
	for _, token in parts do
		if token.kind == "space" or token.kind == "comment" then
			continue
		end
		if token.kind == "div" and token.value == "," then
			table.insert(groups, {} :: { Token })
		else
			table.insert(groups[#groups], token)
		end
	end
	local output: { Token } = {}
	for index, group in groups do
		if #group == 0 then
			return nil, "empty-animation-shorthand-item"
		end
		local name: Token? = nil
		local duration: Token? = nil
		local delay: Token? = nil
		local easing: Token? = nil
		local iterations: Token? = nil
		local direction: Token? = nil
		local fill: Token? = nil
		local state: Token? = nil
		local timeline: Token? = nil
		for _, token in group do
			local value = token.identifier or token.value
			local lower = string.lower(value)
			if token.kind == "word" and token.value:find("\\", 1, true) and not token.identifier then
				return nil, "animation-identifier-metadata-required"
			end
			if
				token.kind == "dimension"
				or token.kind == "number"
				or (token.kind == "function" and mathFunctions[lower])
			then
				local measured, failure = Measurements.resolve({ token }, {})
				if not measured then
					return nil, `animation-number-computation-pending:{failure or "unknown"}`
				end
				if measured.dimension == "time" and measured.percentage == nil then
					if not duration then
						if measured.value < 0 and token.kind ~= "function" then
							return nil, "negative-animation-duration"
						end
						duration = if measured.value < 0 then zero() else token
					elseif not delay then
						delay = token
					else
						return nil, "too-many-animation-times"
					end
				elseif measured.dimension == "number" and measured.percentage == nil and not iterations then
					if measured.value < 0 and token.kind ~= "function" then
						return nil, "negative-animation-iteration-count"
					end
					iterations = if measured.value < 0 then number("0") else token
				else
					return nil, "invalid-animation-number-type"
				end
			elseif token.kind == "word" and easingWords[lower] and not easing then
				easing = word(lower)
			elseif token.kind == "function" and easingFunctions[lower] and not easing then
				local parsed, failure = Easing.parse(token)
				if not parsed then
					return nil, failure
				end
				easing = token
			elseif token.kind == "word" and lower == "infinite" and not iterations then
				iterations = word(lower)
			elseif token.kind == "word" and directions[lower] and not direction then
				direction = word(lower)
			elseif token.kind == "word" and fills[lower] and not fill then
				fill = word(lower)
			elseif token.kind == "word" and states[lower] and not state then
				state = word(lower)
			elseif token.kind == "word" and lower == "auto" and not duration then
				duration = word(lower)
			elseif token.kind == "word" and not timeline and (lower == "auto" or value:sub(1, 2) == "--") then
				timeline = word(value)
			elseif token.kind == "function" and not timeline and (lower == "scroll" or lower == "view") then
				timeline = token
			elseif token.kind == "word" and lower == "none" and name and not timeline then
				timeline = word(lower)
			elseif token.kind == "string" and not name then
				name = token
			elseif token.kind == "word" and not name then
				if forbidden[lower] then
					return nil, "invalid-animation-name"
				end
				name = word(value)
			elseif token.kind == "function" then
				return nil, "animation-shorthand-provider-required"
			else
				return nil, "invalid-animation-shorthand-item"
			end
		end
		local values: { [string]: Token } = {
			["animation-name"] = name or word("none"),
			["animation-duration"] = duration or zero(),
			["animation-delay"] = delay or zero(),
			["animation-timing-function"] = easing or word("ease"),
			["animation-iteration-count"] = iterations or number("1"),
			["animation-direction"] = direction or word("normal"),
			["animation-fill-mode"] = fill or word("none"),
			["animation-play-state"] = state or word("running"),
			["animation-timeline"] = timeline or word("auto"),
			["animation-range-start"] = word("normal"),
			["animation-range-end"] = word("normal"),
		}
		-- Reset-only properties are one initial value, independent of list length.
		if target == "animation-range-start" or target == "animation-range-end" then
			if index == 1 then
				table.insert(output, values[target])
			end
		else
			if index > 1 then
				table.insert(output, { kind = "div", value = "," })
			end
			table.insert(output, values[target])
		end
	end
	return output, nil
end

return AnimationShorthand
