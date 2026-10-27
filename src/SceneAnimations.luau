--!strict

local Types = require(script.Parent.Types)
local Animations = require(script.Parent.Animations)
local Tracks = require(script.Parent.AnimationTracks)
local Values = require(script.Parent.AnimationValues)
local Easing = require(script.Parent.Easing)
local Clock = require(script.Parent.NativeAnimationClock)
local SceneAnimations = {}
export type Track = { source: Tracks.Track, values: { [Tracks.Frame]: Values.Value }? }
export type Effect = { config: Animations.Config, tracks: { [string]: Track } }
export type Data = {
	style: Types.ComputedStyle,
	effects: { Effect },
	bases: { [string]: Values.Value },
	bounds: { [string]: Values.Value },
	controlled: { [string]: boolean },
	rotationNeeded: boolean,
	translationNeeded: boolean,
	scaleNeeded: boolean,
	scaleRange: Values.Range?,
	opacityNeeded: boolean,
}
export type Lookup = (string, Easing.Curve) -> (Tracks.Result?, string?)

function SceneAnimations.needs(effect: Effect, time: number): (boolean, string?)
	local state, failure = Animations.sample(effect.config, time)
	if not state then
		return false, failure
	end
	return state.phase ~= "after" or state.progress ~= nil, nil
end

function SceneAnimations.has(style: Types.ComputedStyle): boolean
	local names = style.properties["animation-name"]
	if not style.properties.animation and not style.unresolved["animation-name"] then
		if not names then
			return false
		end
		local none, seen = true, false
		for _, token in names do
			if token.kind ~= "space" and token.kind ~= "comment" then
				if seen or token.kind ~= "word" or string.lower(token.identifier or token.value) ~= "none" then
					none = false
					break
				end
				seen = true
			end
		end
		if none and seen then
			return false
		end
	end
	return true
end

-- Timing and effect identities must precede layout: active transforms establish
-- containing blocks even when the current animated value is an identity.
function SceneAnimations.resolve(
	style: Types.ComputedStyle,
	lookup: Lookup,
	times: ({ Effect }) -> { number }
): (Data?, string?)
	if not SceneAnimations.has(style) then
		return nil, nil
	end
	local configs, failure = Animations.resolve(style)
	if not configs then
		return nil, failure
	end
	local data: Data = {
		style = style,
		effects = {},
		bases = {},
		bounds = {},
		controlled = {},
		rotationNeeded = false,
		translationNeeded = false,
		scaleNeeded = false,
		opacityNeeded = false,
	}
	for _, config in configs do
		if not config.name then
			continue
		end
		local prepared, reason = lookup(config.name, config.easing)
		if reason then
			return nil, reason
		end
		if not prepared then
			continue
		end
		local effect: Effect = { config = config, tracks = {} }
		for property, track in prepared.properties do
			if track.blocked then
				continue
			end
			if not Values.supports(property) then
				return nil, "animation-property-provider-required:" .. property
			end
			data.controlled[property] = true
			effect.tracks[property] = { source = track }
		end
		table.insert(data.effects, effect)
	end
	if #data.effects == 0 then
		return nil, nil
	end
	local elapsed = times(data.effects)
	for index, effect in data.effects do
		local valid, clockFailure = Clock.validate(effect.config, elapsed[index] or 0, next(effect.tracks) ~= nil)
		if not valid then
			return nil, clockFailure
		end
		local needed, why = SceneAnimations.needs(effect, elapsed[index] or 0)
		if why then
			return nil, why
		end
		if needed then
			data.rotationNeeded = data.rotationNeeded or effect.tracks.transform ~= nil or effect.tracks.rotate ~= nil
			data.translationNeeded = data.translationNeeded or effect.tracks.translate ~= nil
			data.scaleNeeded = data.scaleNeeded or effect.tracks.scale ~= nil
			data.opacityNeeded = data.opacityNeeded or effect.tracks.opacity ~= nil
		end
	end
	return data, nil
end

-- Include neutral lower effects and each interval's easing extrema. Uniform
-- scale needs a signed range rather than a symmetric absolute envelope.
local function scaleRange(
	track: Tracks.Track,
	values: { [Tracks.Frame]: Values.Value },
	lower: Values.Range
): (Values.Range?, string?)
	local result = table.clone(lower)
	local function endpoints(frame: Tracks.Frame): (number, number)
		if frame.underlying then
			return lower.minimum, lower.maximum
		end
		local value = values[frame]
		assert(type(value) == "number", "animation-scale-number-required")
		return value, value
	end
	for index = 1, #track.frames - 1 do
		local aLow, aHigh = endpoints(track.frames[index])
		local bLow, bHigh = endpoints(track.frames[index + 1])
		local pLow, pHigh = Easing.bounds(track.frames[index].easing)
		for _, a in { aLow, aHigh } do
			for _, b in { bLow, bHigh } do
				for _, p in { pLow, pHigh } do
					local value = (1 - p) * a + p * b
					if value ~= value or math.abs(value) == math.huge then
						return nil, "animation-scale-arithmetic-range-required"
					end
					result.minimum, result.maximum = math.min(result.minimum, value), math.max(result.maximum, value)
				end
			end
		end
	end
	return result, nil
end

-- Endpoint computation uses this commit's used box, font and viewport context.
-- Prepared snapshots own their numerical values; timing snapshots stay immutable.
function SceneAnimations.prepare(data: Data, context: Values.Context): (Data?, string?)
	local result = table.clone(data)
	result.effects, result.bases, result.bounds = {}, {}, {}
	result.scaleRange = nil
	for _, source in data.effects do
		local effect: Effect = { config = source.config, tracks = {} }
		for property, track in source.tracks do
			if result.bases[property] == nil then
				local failure = data.style.unresolved[property]
				if failure then
					return nil, failure
				end
				local base, why = Values.resolve(property, data.style.properties[property], context)
				if base == nil then
					return nil, why
				end
				result.bases[property] = base
				if property == "scale" then
					assert(type(base) == "number", "animation-scale-number-required")
					result.scaleRange = { minimum = base, maximum = base }
				end
				local bound, reason = Values.bound(base)
				if bound == nil then
					return nil, reason
				end
				result.bounds[property] = bound
			end
			local values: { [Tracks.Frame]: Values.Value } = {}
			local bound = result.bounds[property]
			for _, frame in track.source.frames do
				if frame.unresolved then
					return nil, frame.unresolved
				end
				if not frame.underlying then
					local value, why = Values.resolve(property, frame.tokens, context)
					if value == nil then
						return nil, why
					end
					values[frame] = value
					local nextBound, reason = Values.bound(value, bound)
					if nextBound == nil then
						return nil, reason
					end
					bound = nextBound
				end
			end
			local factor = 1
			for index = 1, #track.source.frames - 1 do
				local low, high = Easing.bounds(track.source.frames[index].easing)
				factor = math.max(factor, math.abs(1 - low) + math.abs(low), math.abs(1 - high) + math.abs(high))
			end
			local nextBound, reason = Values.bound(bound, nil, factor)
			if nextBound == nil then
				return nil, reason
			end
			result.bounds[property] = nextBound
			if property == "scale" then
				local range, failure = scaleRange(track.source, values, assert(result.scaleRange))
				if not range then
					return nil, failure
				end
				result.scaleRange = range
			end
			effect.tracks[property] = { source = track.source, values = values }
		end
		table.insert(result.effects, effect)
	end
	return result, nil
end

return SceneAnimations
