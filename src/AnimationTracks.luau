--!strict

local Types = require(script.Parent.Types)
local Variables = require(script.Parent.Variables)
local LogicalProperties = require(script.Parent.LogicalProperties)
local Cascade = require(script.Parent.Cascade)
local Easing = require(script.Parent.Easing)

type Token = Types.ValueToken
export type Frame = {
	offset: number,
	tokens: { Token }?,
	underlying: boolean,
	easing: Easing.Curve,
	unresolved: string?,
}
export type Track = { property: string, blocked: boolean, frames: { Frame } }
export type Result = { name: string, properties: { [string]: Track } }
export type Interval = { start: Frame, finish: Frame, progress: number }
export type Context = {
	style: Types.ComputedStyle,
	parent: Types.ComputedStyle?,
	metadata: { [string]: Types.PropertyMetadata },
	registrations: { [string]: Types.Registration },
	defaults: Variables.Defaults?,
}
local AnimationTracks = {}

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

-- This prepares independent property tracks. Consuming backends still compute
-- typed property values with current geometry/font dependencies and interpolate.
-- Other properties declared in a keyframe are never its dependency context.
function AnimationTracks.resolve(
	definition: Types.PreparedKeyframes,
	context: Context,
	defaultEasing: Easing.Curve
): (Result?, string?)
	local names, mappingFailure = LogicalProperties.names(context.style)
	if not names then
		return nil, mappingFailure
	end
	local output: Result = { name = definition.name, properties = {} }
	local function frameValue(winners: { [string]: Types.Declaration }): Types.ComputedStyle
		return Variables.compute(winners, context.parent, context.registrations, function() end,
			context.metadata, nil, context.defaults, nil, context.style)
	end
	local function append(
		property: string,
		offset: number,
		tokens: { Token }?,
		easing: Easing.Curve,
		unresolved: string?
	)
		local track = output.properties[property]
		if not track then
			local priority = context.style.priorities[property]
			track = { property = property, blocked = priority ~= nil and priority.important, frames = {} }
			output.properties[property] = track
		end
		table.insert(
			track.frames,
			{ offset = offset, tokens = tokens, underlying = false, easing = easing, unresolved = unresolved }
		)
	end
	for _, frame in definition.frames do
		local winners: { [string]: Types.Declaration } = {}
		local custom: { [string]: Types.Declaration } = {}
		local metadataPending: { [string]: string } = {}
		for index, declaration in frame.declarations do
			if declaration.important or declaration.validity == "invalid" then
				continue
			end
			local property = declaration.property
			local special = property == "animation-timing-function" or property == "animation-composition"
			if property == "animation" or (property:sub(1, 10) == "animation-" and not special) then
				continue
			end
			local info = context.metadata[property]
			if not special and info and info.animationType == "notAnimatable" then
				continue
			end
			local target = names[property] or property
			if not special and property:sub(1, 2) ~= "--" and (not info or info.animationType == nil) then
				metadataPending[target] = "animation-type-metadata-required"
			end
			local candidate = table.clone(declaration)
			local priority: Types.Priority = {
				important = false,
				layer = {},
				specificity = { 0, 0, 0 },
				order = declaration.cascadeOrder or index,
				logical = target ~= property,
			}
			candidate.priority = priority
			local collection = if property:sub(1, 2) == "--" then custom else winners
			local previous = collection[target]
			if not previous or Cascade.outranks(priority, assert(previous.priority)) then
				collection[target] = candidate
			end
		end
		local computed = frameValue(winners)
		local easing = defaultEasing
		if winners["animation-composition"] then
			local value = computed.properties["animation-composition"]
			local significant = {}
			for _, token in value or {} do
				if token.kind ~= "space" and token.kind ~= "comment" then
					table.insert(significant, token)
				end
			end
			if
				computed.unresolved["animation-composition"]
				or #significant ~= 1
				or significant[1].kind ~= "word"
				or string.lower(significant[1].identifier or significant[1].value) ~= "replace"
			then
				return nil, "keyframe-composition-provider-required"
			end
		end
		if winners["animation-timing-function"] then
			local tokens = {}
			for _, token in computed.properties["animation-timing-function"] or {} do
				if token.kind ~= "space" and token.kind ~= "comment" then
					table.insert(tokens, token)
				end
			end
			if computed.unresolved["animation-timing-function"] or #tokens ~= 1 then
				return nil, "keyframe-easing-provider-required"
			end
			local token = tokens[1]
			if token.identifier then
				token = table.clone(token)
				token.value = token.identifier :: string
			end
			local curve, failure = Easing.parse(token)
			if not curve then
				return nil, failure
			end
			easing = curve
		end
		for property in winners do
			if property == "animation-timing-function" or property == "animation-composition" then
				continue
			end
			local tokens = computed.properties[property]
			append(
				property,
				frame.offset,
				tokens,
				easing,
				computed.unresolved[property]
					or metadataPending[property]
					or (if tokens == nil then "keyframe-value-provider-required" else nil)
			)
		end
		for property, declaration in custom do
			-- Resolve each animated custom property against current target values.
			-- It must not rebind unrelated endpoint values in this keyframe.
			local values = frameValue({ [property] = declaration })
			local tokens = values.variables[property]
			append(
				property,
				frame.offset,
				tokens,
				easing,
				(values.unresolvedVariables and values.unresolvedVariables[property])
					or (if tokens == nil then "keyframe-custom-value-provider-required" else nil)
			)
		end
	end
	for _, track in output.properties do
		local frames = track.frames
		if frames[1].offset ~= 0 then
			table.insert(frames, 1, { offset = 0, underlying = true, easing = defaultEasing })
		end
		if frames[#frames].offset ~= 1 then
			table.insert(frames, { offset = 1, underlying = true, easing = defaultEasing })
		end
	end
	-- The caller owns the returned token/easing graphs; prepared sheets and
	-- computed node snapshots keep their immutable ownership.
	return copy(output), nil
end

-- Prepared tracks have unique, ascending offsets and explicit/neutral 0/1
-- endpoints. Return references into the caller-owned track, not private state.
function AnimationTracks.interval(track: Track, progress: number, before: boolean?): (Interval?, string?)
	if track.blocked then
		return nil, nil
	end
	if progress ~= progress or math.abs(progress) == math.huge then
		return nil, "animation-progress-range-required"
	end
	local frames = track.frames
	if #frames < 2 then
		return nil, "invalid-animation-track"
	end
	local low, high = 1, #frames - 1
	while low < high do
		local middle = math.ceil((low + high) / 2)
		if frames[middle].offset <= progress then
			low = middle
		else
			high = middle - 1
		end
	end
	local a, b = frames[low], frames[low + 1]
	if a.offset >= b.offset then
		return nil, "invalid-animation-track"
	end
	if a.unresolved or b.unresolved then
		return nil, a.unresolved or b.unresolved
	end
	local distance = (progress - a.offset) / (b.offset - a.offset)
	if distance ~= distance or math.abs(distance) == math.huge then
		return nil, "animation-interval-arithmetic-range-required"
	end
	local eased = Easing.sample(a.easing, distance, before)
	if eased ~= eased or math.abs(eased) == math.huge then
		return nil, "animation-interval-arithmetic-range-required"
	end
	return { start = a, finish = b, progress = eased }, nil
end

return AnimationTracks
