--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local CssEasing = require(script.Parent.Easing)
export type Easing = CssEasing.Curve
export type Config = { duration: number, delay: number, easing: Easing, allowDiscrete: boolean? }
local Transitions = {}
local defaults: { [string]: { Types.ValueToken } } = {
	property = { { kind = "word", value = "all" } },
	duration = { { kind = "dimension", value = "0", unit = "s" } },
	delay = { { kind = "dimension", value = "0", unit = "s" } },
	easing = { { kind = "word", value = "ease" } },
	behavior = { { kind = "word", value = "normal" } },
}
local fields = {
	"transition-property",
	"transition-duration",
	"transition-delay",
	"transition-timing-function",
	"transition-behavior",
}
local function list(tokens: { Types.ValueToken }): { { Types.ValueToken } }
	local result: { { Types.ValueToken } } = { {} }
	for _, token in tokens do
		if token.kind == "div" and token.value == "," then
			table.insert(result, {} :: { Types.ValueToken })
		elseif token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(result[#result], token)
		end
	end
	return result
end
local function entry(tokens: { Types.ValueToken }, selected: number): { Types.ValueToken }
	-- A lone value already is its list entry. Keep complex lists on the shared
	-- splitter so comments, empty entries and modulo repetition retain meaning.
	if #tokens == 1 and tokens[1].kind ~= "space" and tokens[1].kind ~= "comment" and tokens[1].kind ~= "div" then
		return tokens
	end
	local entries = list(tokens)
	return entries[(selected - 1) % #entries + 1]
end
local function time(tokens: { Types.ValueToken }): number?
	local value = Measurements.resolve(tokens, {})
	return if value and value.dimension == "time" and value.percentage == nil then value.value else nil
end
function Transitions.validate(config: Config): string?
	for _, value in { config.duration, config.delay } do
		if value ~= value or math.abs(value) == math.huge then
			return "invalid-transition-config"
		end
	end
	if config.duration < 0 or config.duration > 86400 or math.abs(config.delay) > 86400 then
		return "transition-time-budget-provider-required"
	end
	local curve = config.easing
	local function finite(n: number): boolean
		return n == n and math.abs(n) < math.huge
	end
	if curve.kind == "bezier" then
		for _, n in { curve.x1, curve.y1, curve.x2, curve.y2 } do
			if not finite(n) then
				return "invalid-transition-easing"
			end
		end
		if curve.x1 < 0 or curve.x1 > 1 or curve.x2 < 0 or curve.x2 > 1 then
			return "invalid-transition-easing"
		end
	elseif curve.kind == "steps" then
		if
			not finite(curve.count)
			or curve.count % 1 ~= 0
			or curve.count < 1
			or curve.count > 2147483647
			or (curve.jump == "none" and curve.count < 2)
		then
			return "invalid-transition-easing"
		end
	elseif curve.kind == "linear" then
		if #curve.points < 2 or #curve.points > 2048 then
			return "invalid-transition-easing"
		end
		local previous = -math.huge
		for _, point in curve.points do
			if not finite(point.input) or not finite(point.output) or point.input < previous then
				return "invalid-transition-easing"
			end
			previous = point.input
		end
	end
	local low, high = CssEasing.bounds(config.easing)
	if low < 0 or high > 1 or low ~= low or high ~= high then
		return "transition-easing-envelope-provider-required"
	end
	return nil
end
function Transitions.resolve(style: Types.ComputedStyle, property: string): (Config?, string?)
	if style.properties.transition then
		return nil, "transition-shorthand-provider-required"
	end
	local propertyTokens = style.properties["transition-property"] or defaults.property
	local selected: number? = nil
	if #propertyTokens == 1 and propertyTokens[1].kind == "word" then
		local raw = propertyTokens[1].value
		local name = if raw:sub(1, 2) == "--" then raw else string.lower(raw)
		if name == property or name == "all" then
			selected = 1
		end
	else
		for index, propertyEntry in list(propertyTokens) do
			if #propertyEntry ~= 1 or propertyEntry[1].kind ~= "word" then
				return nil, "invalid-transition-property-list"
			end
			local raw = propertyEntry[1].value
			local name = if raw:sub(1, 2) == "--" then raw else string.lower(raw)
			if name == property or name == "all" then
				selected = index
			end
		end
	end
	if not selected then
		return nil, nil
	end
	for _, name in fields do
		if style.unresolved[name] then
			return nil, `{name}:{style.unresolved[name]}`
		end
	end
	local duration = time(entry(style.properties["transition-duration"] or defaults.duration, selected))
	local delay = time(entry(style.properties["transition-delay"] or defaults.delay, selected))
	local easingTokens = entry(style.properties["transition-timing-function"] or defaults.easing, selected)
	local curve: Easing? = nil
	local curveFailure: string? = nil
	if #easingTokens == 1 then
		curve, curveFailure = CssEasing.parse(easingTokens[1])
	else
		curveFailure = "invalid-transition-easing-list"
	end
	local behavior = entry(style.properties["transition-behavior"] or defaults.behavior, selected)
	if
		#behavior ~= 1
		or behavior[1].kind ~= "word"
		or (string.lower(behavior[1].value) ~= "normal" and string.lower(behavior[1].value) ~= "allow-discrete")
	then
		return nil, "invalid-transition-behavior"
	end
	if not duration or duration < 0 or not delay then
		return nil, "transition-time-provider-required"
	end
	if not curve then
		return nil, curveFailure or "transition-easing-provider-required"
	end
	local config: Config = {
		duration = duration,
		delay = delay,
		easing = curve,
		allowDiscrete = string.lower(behavior[1].value) == "allow-discrete",
	}
	local failure = Transitions.validate(config)
	return if failure then nil else config, failure
end
Transitions.ease = CssEasing.sample
return Transitions
