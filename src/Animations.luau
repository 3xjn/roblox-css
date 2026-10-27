--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local Easing = require(script.Parent.Easing)
local AnimationTiming = require(script.Parent.AnimationTiming)
local AnimationTracks = require(script.Parent.AnimationTracks)
type Token = Types.ValueToken
export type Config = {
	index: number,
	name: string?,
	duration: number,
	delay: number,
	iterations: number,
	direction: string,
	fill: string,
	paused: boolean,
	easing: Easing.Curve,
}
local Animations = {}
Animations.sample = AnimationTiming.sample
Animations.interval = AnimationTracks.interval
local defaults: { [string]: { Token } } = {
	["animation-name"] = { { kind = "word", value = "none" } },
	["animation-duration"] = { { kind = "dimension", value = "0", unit = "s" } },
	["animation-delay"] = { { kind = "dimension", value = "0", unit = "s" } },
	["animation-timing-function"] = { { kind = "word", value = "ease" } },
	["animation-iteration-count"] = { { kind = "number", value = "1" } },
	["animation-direction"] = { { kind = "word", value = "normal" } },
	["animation-fill-mode"] = { { kind = "word", value = "none" } },
	["animation-play-state"] = { { kind = "word", value = "running" } },
	["animation-timeline"] = { { kind = "word", value = "auto" } },
	["animation-range-start"] = { { kind = "word", value = "normal" } },
	["animation-range-end"] = { { kind = "word", value = "normal" } },
	["animation-composition"] = { { kind = "word", value = "replace" } },
}
local directions = { normal = true, reverse = true, alternate = true, ["alternate-reverse"] = true }
local fills = { none = true, forwards = true, backwards = true, both = true }
local states = { running = true, paused = true }
local forbidden =
	{ initial = true, inherit = true, unset = true, revert = true, ["revert-layer"] = true, default = true }

local function split(tokens: { Token }): { { Token } }
	local groups: { { Token } } = { {} }
	for _, token in tokens do
		if token.kind == "div" and token.value == "," then
			table.insert(groups, {} :: { Token })
		elseif token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(groups[#groups], token)
		end
	end
	return groups
end
local function keyword(tokens: { Token }): string?
	local token = if #tokens == 1 then tokens[1] else nil
	return if token and token.kind == "word" then string.lower(token.identifier or token.value) else nil
end

-- Timing/list computation only. Applying an effect needs keyframe value
-- resolution, animation cascade priority and a qualified native property backend.
function Animations.resolve(style: Types.ComputedStyle): ({ Config }?, string?)
	if style.properties.animation then
		return nil, "animation-shorthand-provider-required"
	end
	local names = split(style.properties["animation-name"] or defaults["animation-name"])
	if not style.unresolved["animation-name"] and #names == 1 and keyword(names[1]) == "none" then
		return {}, nil
	end
	local lists: { [string]: { { Token } } } = {}
	for property, initial in defaults do
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
		local groups = split(style.properties[property] or initial)
		for _, group in groups do
			if #group == 0 then
				return nil, `empty-animation-list-item:{property}`
			end
		end
		lists[property] = groups
	end
	local function entry(property: string, index: number): { Token }
		local groups = lists[property]
		return groups[(index - 1) % #groups + 1]
	end
	local configs: { Config } = {}
	for index, group in names do
		if #group ~= 1 or (group[1].kind ~= "word" and group[1].kind ~= "string") then
			return nil, "animation-name-provider-required"
		end
		local token = group[1]
		if token.kind == "word" and token.value:find("\\", 1, true) and not token.identifier then
			return nil, "animation-identifier-metadata-required"
		end
		local name = token.identifier or token.value
		if token.kind == "word" and forbidden[string.lower(name)] then
			return nil, "invalid-animation-name"
		end
		local durationTokens = entry("animation-duration", index)
		local duration = if keyword(durationTokens) == "auto"
			then { value = 0, dimension = "time", percentage = nil }
			else Measurements.resolve(durationTokens, {})
		local delay = Measurements.resolve(entry("animation-delay", index), {})
		local countTokens = entry("animation-iteration-count", index)
		local count = if keyword(countTokens) == "infinite" then math.huge else nil
		if count == nil then
			local measured = Measurements.resolve(countTokens, {})
			if measured and measured.dimension == "number" and measured.percentage == nil then
				count = measured.value
			end
		end
		if not duration or duration.dimension ~= "time" or duration.percentage ~= nil or duration.value < 0 then
			return nil, "animation-duration-provider-required"
		end
		if not delay or delay.dimension ~= "time" or delay.percentage ~= nil then
			return nil, "animation-delay-provider-required"
		end
		if count == nil or count < 0 then
			return nil, "animation-iteration-count-provider-required"
		end
		local timing = entry("animation-timing-function", index)
		if #timing ~= 1 then
			return nil, "animation-easing-provider-required"
		end
		local timingToken = timing[1]
		if timingToken.identifier then
			timingToken = table.clone(timingToken)
			timingToken.value = timingToken.identifier :: string
		end
		local easing, easingFailure = Easing.parse(timingToken)
		if not easing then
			return nil, easingFailure
		end
		local direction = keyword(entry("animation-direction", index))
		local fill = keyword(entry("animation-fill-mode", index))
		local state = keyword(entry("animation-play-state", index))
		if not direction or not directions[direction] then
			return nil, "animation-direction-provider-required"
		end
		if not fill or not fills[fill] then
			return nil, "animation-fill-mode-provider-required"
		end
		if not state or not states[state] then
			return nil, "animation-play-state-provider-required"
		end
		if keyword(entry("animation-timeline", index)) ~= "auto" then
			return nil, "animation-timeline-provider-required"
		end
		if
			keyword(entry("animation-range-start", index)) ~= "normal"
			or keyword(entry("animation-range-end", index)) ~= "normal"
		then
			return nil, "animation-range-provider-required"
		end
		if keyword(entry("animation-composition", index)) ~= "replace" then
			return nil, "animation-composition-provider-required"
		end
		table.insert(
			configs,
			{
				index = index,
				name = if token.kind == "word" and string.lower(name) == "none" then nil else name,
				duration = duration.value,
				delay = delay.value,
				iterations = count,
				direction = direction,
				fill = fill,
				paused = state == "paused",
				easing = easing,
			}
		)
	end
	return configs, nil
end

return Animations
