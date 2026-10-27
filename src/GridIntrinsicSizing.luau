--!strict

local GridTracks = require(script.Parent.GridTracks)
local GridTrackSizing = require(script.Parent.GridTrackSizing)
local Measurements = require(script.Parent.Measurements)
local WorkQueue = require(script.Parent.WorkQueue)

export type Contribution = { first: number, last: number, minimum: number, minContent: number, maxContent: number }
export type Context = {
	lengths: Measurements.Context,
	available: number?,
	gap: number?,
	constraint: ("min-content" | "max-content")?,
}
export type Result = { tracks: { GridTrackSizing.Track }, deferredPercentages: boolean }
type State = {
	base: number,
	limit: number,
	minimum: string,
	maximum: string,
	flex: number?,
	fit: number?,
	fixedMaximum: number?,
}
type Predicate = (State) -> boolean
type Mode = "minimum" | "minContent" | "maxContent" | "limitedMin" | "limitedMax"

local GridIntrinsicSizing = {}
local maximumFinite = 1.7976931348623157e308

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function intrinsic(kind: string): boolean
	return kind == "auto" or kind == "min-content" or kind == "max-content"
end

local function contentMaximum(state: State): boolean
	return state.maximum == "auto" or state.maximum == "max-content"
end

local function length(breadth: GridTracks.Breadth, context: Context): (number?, boolean, string?)
	if not breadth.tokens then
		return nil, false, "grid-track-length-tokens-required"
	end
	local units = table.clone(context.lengths)
	units.allowRatio = nil
	units.percentageDimension, units.percentageBasis = "length", context.available
	units.mathRange = { minimum = 0, maximum = maximumFinite }
	local value, failure = Measurements.resolve(breadth.tokens, units)
	local percentage = Measurements.hasPercentage(breadth.tokens)
	if not value then
		if
			context.available == nil
			and percentage
			and (failure == "percentage-basis-required" or failure == "math-range-percentage-basis-required")
		then
			return nil, true, nil
		end
		return nil, false, `grid-track-length-provider-required:{failure or "unknown"}`
	end
	if value.dimension ~= "length" and not (value.dimension == "number" and value.value == 0) then
		return nil, false, "grid-track-length-required"
	end
	if context.available == nil and percentage then
		return nil, true, nil
	end
	local scalar = Measurements.toScalar(value, units)
	if scalar == nil or not finite(scalar) then
		return nil, false, "grid-track-length-range-provider-required"
	end
	if scalar < 0 then
		return nil, false, "negative-grid-track-size"
	end
	return scalar, false, nil
end

local function initialize(definition: GridTracks.Track, context: Context): (State?, boolean, string?)
	local minimum, maximum = definition.minimum.kind, definition.maximum.kind
	local base, limit = 0, math.huge
	local deferred = false
	if minimum == "length" then
		local number, pending, failure = length(definition.minimum, context)
		if failure then
			return nil, false, failure
		end
		base, minimum, deferred = number or 0, if pending then "auto" else minimum, pending
	elseif not intrinsic(minimum) then
		return nil, false, "invalid-grid-minimum-track-function"
	end
	if maximum == "length" then
		local number, pending, failure = length(definition.maximum, context)
		if failure then
			return nil, false, failure
		end
		limit, maximum, deferred = number or math.huge, if pending then "auto" else maximum, deferred or pending
	elseif maximum ~= "flex" and not intrinsic(maximum) then
		return nil, false, "invalid-grid-maximum-track-function"
	end
	local factor = definition.maximum.factor
	if maximum == "flex" and (factor == nil or not finite(factor) or factor < 0) then
		return nil, false, "invalid-grid-track-flex-factor"
	end
	local fit: number? = nil
	if definition.fitContent then
		local number, pending, failure = length({ kind = "length", tokens = definition.fitContent }, context)
		if failure then
			return nil, false, failure
		end
		fit, deferred = number, deferred or pending
	end
	return {
		base = base,
		limit = math.max(base, limit),
		minimum = minimum,
		maximum = maximum,
		flex = if maximum == "flex" then factor else nil,
		fit = fit,
		fixedMaximum = if maximum == "length" then math.max(base, limit) else nil,
	},
		deferred,
		nil
end

local function current(state: State, field: string): number
	return if field == "base" or state.limit == math.huge then state.base else state.limit
end

-- All sizes are outer contributions with their own sizing constraints already
-- applied. The track limit only caps a limited contribution when every spanned
-- maximum is fixed; single-track fit-content also supplies a cap.
local function contribution(item: Contribution, states: { State }, mode: Mode, gap: number): number
	if mode == "minimum" then
		return item.minimum
	end
	if mode == "minContent" then
		return item.minContent
	end
	if mode == "maxContent" then
		return item.maxContent
	end
	local limit = gap * (item.last - item.first)
	for index = item.first, item.last do
		local state = states[index]
		if state.maximum == "length" then
			limit += assert(state.fixedMaximum)
		elseif item.first == item.last and state.fit then
			limit += state.fit
		else
			limit = math.huge
			break
		end
	end
	return math.max(item.minimum, math.min(limit, if mode == "limitedMin" then item.minContent else item.maxContent))
end

-- Distribute one item's remaining space with limits. Every pass either spends
-- all space or freezes a track, so the loop is bounded by the candidate count.
local function grow(
	indices: { number },
	space: number,
	states: { State },
	sizes: { [number]: number },
	increases: { [number]: number },
	limits: { [number]: number },
	weighted: boolean
): number
	local active = table.clone(indices)
	while space > 0 and #active > 0 do
		WorkQueue.checkpoint()
		local factors = 0
		if weighted then
			for _, index in active do
				factors += states[index].flex or 0
			end
		end
		local weights, total = {}, 0
		for _, index in active do
			local weight = if weighted then (states[index].flex or 0) + math.max(0, 1 - factors) / #active else 1
			weights[index] = weight
			total += weight
		end
		if total <= 0 or not finite(total) then
			return space
		end
		local frozen: { [number]: boolean } = {}
		local count = 0
		for _, index in active do
			WorkQueue.checkpoint()
			local capacity = math.max(0, limits[index] - sizes[index] - (increases[index] or 0))
			local share = space * (weights[index] / total)
			if capacity <= share then
				frozen[index] = true
				count += 1
			end
		end
		if count == 0 then
			for _, index in active do
				increases[index] = (increases[index] or 0) + space * (weights[index] / total)
			end
			return 0
		end
		local nextActive = {}
		for _, index in active do
			if frozen[index] then
				local capacity = math.max(0, limits[index] - sizes[index] - (increases[index] or 0))
				increases[index] = (increases[index] or 0) + capacity
				space = math.max(0, space - capacity)
			else
				table.insert(nextActive, index)
			end
		end
		active = nextActive
	end
	return space
end

local function distribute(
	states: { State },
	items: { Contribution },
	field: string,
	mode: Mode,
	affected: Predicate,
	context: Context,
	flexible: boolean,
	infinitelyGrowable: { [number]: boolean }?
)
	local planned: { [number]: number } = {}
	local gap = context.gap or 0
	for _, item in items do
		WorkQueue.checkpoint()
		local sizes, limits, increases = {}, {}, {}
		local eligible, other = {}, {}
		local occupied = gap * (item.last - item.first)
		for index = item.first, item.last do
			local state = states[index]
			sizes[index] = current(state, field)
			occupied += sizes[index]
			if not flexible or state.flex ~= nil then
				if affected(state) then
					table.insert(eligible, index)
				else
					table.insert(other, index)
				end
			end
			if field == "base" then
				limits[index] = math.min(state.limit, state.fit or math.huge)
			else
				limits[index] = if state.limit < math.huge
						and not (infinitelyGrowable and infinitelyGrowable[index])
					then state.limit
					else state.fit or math.huge
			end
		end
		if #eligible == 0 then
			continue
		end
		for _, index in eligible do
			planned[index] = planned[index] or 0
		end
		local space = math.max(0, contribution(item, states, mode, gap) - occupied)
		space = grow(eligible, space, states, sizes, increases, limits, flexible)
		if space > 0 then
			space = grow(other, space, states, sizes, increases, limits, flexible)
		end
		while space > 0 do
			WorkQueue.checkpoint()
			local beyond, caps = {}, {}
			for _, index in eligible do
				local state = states[index]
				local isIntrinsic = if field == "base" and (mode == "maxContent" or mode == "limitedMax")
					then contentMaximum(state)
					else intrinsic(state.maximum)
				if isIntrinsic and (state.fit == nil or sizes[index] + (increases[index] or 0) < state.fit) then
					table.insert(beyond, index)
					caps[index] = state.fit or math.huge
				end
			end
			if #beyond == 0 then
				if field ~= "base" then
					break
				end
				beyond = eligible
				for _, index in beyond do
					caps[index] = math.huge
				end
			end
			local remaining = grow(beyond, space, states, sizes, increases, caps, flexible)
			if remaining >= space then
				break
			end
			space = remaining
		end
		for index, increase in increases do
			planned[index] = math.max(planned[index] or 0, increase)
		end
	end
	for index, increase in planned do
		local state = states[index]
		local size = current(state, field) + increase
		if field == "base" then
			state.base = size
		else
			state.limit = size
		end
	end
end

local function floorLimits(states: { State })
	for _, state in states do
		state.limit = math.max(state.base, state.limit)
	end
end

local function spanning(states: { State }, items: { Contribution }, context: Context, flexible: boolean)
	distribute(states, items, "base", if context.constraint then "limitedMin" else "minimum", function(s)
		return intrinsic(s.minimum)
	end, context, flexible)
	distribute(states, items, "base", "minContent", function(s)
		return s.minimum == "min-content" or s.minimum == "max-content"
	end, context, flexible)
	if context.constraint == "max-content" then
		distribute(states, items, "base", "limitedMax", function(s)
			return s.minimum == "auto" or s.minimum == "max-content"
		end, context, flexible)
	end
	distribute(states, items, "base", "maxContent", function(s)
		return s.minimum == "max-content"
	end, context, flexible)
	floorLimits(states)
	local before: { [number]: boolean } = {}
	for index, state in states do
		if state.limit == math.huge then
			before[index] = true
		end
	end
	distribute(states, items, "limit", "minContent", function(s)
		return intrinsic(s.maximum)
	end, context, flexible)
	local infinitelyGrowable: { [number]: boolean } = {}
	for index in before do
		if states[index].limit < math.huge then
			infinitelyGrowable[index] = true
		end
	end
	distribute(states, items, "limit", "maxContent", contentMaximum, context, flexible, infinitelyGrowable)
	floorLimits(states)
end

-- Initialize used track functions and perform intrinsic track sizing. Item
-- contributions are supplied by the formatting owner, including baseline shims
-- where required. Neither the definitions nor caller contributions are mutated.
function GridIntrinsicSizing.resolve(
	definitions: { GridTracks.Track },
	items: { Contribution },
	context: Context
): (Result?, string?)
	if context.available ~= nil and (not finite(context.available) or context.available < 0) then
		return nil, "invalid-grid-available-space"
	end
	if not finite(context.gap or 0) or (context.gap or 0) < 0 then
		return nil, "invalid-grid-track-gap"
	end
	if context.constraint ~= nil and context.constraint ~= "min-content" and context.constraint ~= "max-content" then
		return nil, "invalid-grid-sizing-constraint"
	end
	local states: { State } = {}
	local deferred = false
	local factors = 0
	for _, definition in definitions do
		WorkQueue.checkpoint()
		local state, pending, failure = initialize(definition, context)
		if not state then
			return nil, failure
		end
		deferred = deferred or pending
		factors += state.flex or 0
		if not finite(factors) then
			return nil, "grid-flex-factor-range-provider-required"
		end
		table.insert(states, state)
	end
	local singles: { [number]: { Contribution } } = {}
	local groups: { [number]: { Contribution } } = {}
	local flexible: { Contribution } = {}
	for _, input in items do
		WorkQueue.checkpoint()
		if
			input.first < 1
			or input.last > #states
			or input.last < input.first
			or input.first % 1 ~= 0
			or input.last % 1 ~= 0
			or not finite(input.minimum)
			or not finite(input.minContent)
			or not finite(input.maxContent)
			or input.minimum > input.minContent
			or input.minContent > input.maxContent
		then
			return nil, "invalid-grid-intrinsic-contribution"
		end
		local item = {
			first = input.first,
			last = input.last,
			minimum = math.max(0, input.minimum),
			minContent = math.max(0, input.minContent),
			maxContent = math.max(0, input.maxContent),
		}
		local hasFlex = false
		for index = item.first, item.last do
			if states[index].flex ~= nil then
				hasFlex = true
				break
			end
		end
		if hasFlex then
			table.insert(flexible, item)
		elseif item.first == item.last then
			local list = singles[item.first] or {}
			singles[item.first] = list
			table.insert(list, item)
		else
			local span = item.last - item.first + 1
			local list = groups[span] or {}
			groups[span] = list
			table.insert(list, item)
		end
	end
	for index, list in singles do
		local state = states[index]
		local limit = 0
		for _, item in list do
			local minimum = if state.minimum == "min-content"
				then item.minContent
				elseif state.minimum == "max-content" then item.maxContent
				elseif state.minimum == "auto" then contribution(
					item,
					states,
					if context.constraint then "limitedMin" else "minimum",
					context.gap or 0
				)
				else 0
			state.base = math.max(state.base, minimum)
			if intrinsic(state.maximum) then
				local maximum = if state.maximum == "min-content" then item.minContent else item.maxContent
				limit = math.max(limit, math.min(maximum, state.fit or math.huge))
			end
		end
		if intrinsic(state.maximum) then
			state.limit = limit
		end
		state.limit = math.max(state.base, state.limit)
	end
	local spans = {}
	for span in groups do
		table.insert(spans, span)
	end
	table.sort(spans)
	for _, span in spans do
		spanning(states, groups[span], context, false)
	end
	spanning(states, flexible, context, true)
	local result: { GridTrackSizing.Track } = {}
	for _, state in states do
		WorkQueue.checkpoint()
		local limit = if state.limit == math.huge then state.base else state.limit
		if not finite(state.base) or not finite(limit) then
			return nil, "grid-track-size-range-provider-required"
		end
		table.insert(
			result,
			{ base = state.base, limit = limit, flex = state.flex, stretchable = state.maximum == "auto" }
		)
	end
	return { tracks = result, deferredPercentages = deferred }, nil
end

return GridIntrinsicSizing
