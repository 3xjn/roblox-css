--!strict

local WorkQueue = require(script.Parent.WorkQueue)

-- Inputs are the completed intrinsic-sizing phase, not arbitrary CSS widths.
-- A growth limit must already be finite and at least the base size. Flexible
-- tracks retain a factor; only auto maxima are stretchable. The caller applies
-- container min/max constraints before supplying available grid space.
export type Track = { base: number, limit: number, flex: number?, stretchable: boolean? }
export type Contribution = { first: number, last: number, maximum: number }
export type Context = {
	available: number?,
	gap: number?,
	constraint: ("min-content" | "max-content")?,
	stretch: boolean?,
	contributions: { Contribution }?,
}
export type Result = { sizes: { number }, offsets: { number }, extent: number, remaining: number?, fraction: number }

local GridTrackSizing = {}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

type Capacity = { index: number, capacity: number }
type Flexible = { index: number, factor: number, threshold: number }

-- Water filling visits each capacity once after sorting, rather than repeatedly
-- scanning all tracks when small growth limits freeze one at a time.
local function maximize(sizes: { number }, tracks: { Track }, free: number)
	local candidates: { Capacity } = {}
	for index, value in tracks do
		WorkQueue.checkpoint()
		if value.flex == nil and value.limit > sizes[index] then
			table.insert(candidates, { index = index, capacity = value.limit - sizes[index] })
		end
	end
	table.sort(candidates, function(a: Capacity, b: Capacity)
		return a.capacity < b.capacity
	end)
	for position, value in candidates do
		WorkQueue.checkpoint()
		local share = free / (#candidates - position + 1)
		if value.capacity <= share then
			sizes[value.index] += value.capacity
			free -= value.capacity
		else
			for index = position, #candidates do
				WorkQueue.checkpoint()
				sizes[candidates[index].index] += share
			end
			break
		end
	end
end

-- CSS Grid's fr restart rule. Sort by the base/factor threshold so a frozen
-- track is removed once. Suffix sums avoid cancellation when a large factor
-- freezes ahead of a much smaller one.
local function fraction(
	sizes: { number },
	tracks: { Track },
	first: number,
	last: number,
	space: number,
	gap: number
): (number?, string?)
	local leftover = space - math.max(0, last - first) * gap
	local candidates: { Flexible } = {}
	for index = first, last do
		WorkQueue.checkpoint()
		local factor = tracks[index].flex
		if factor and factor > 0 then
			table.insert(candidates, { index = index, factor = factor, threshold = sizes[index] / factor })
		else
			leftover -= sizes[index]
		end
	end
	table.sort(candidates, function(a: Flexible, b: Flexible)
		return a.threshold > b.threshold
	end)
	local sums: { number } = {}
	local total = 0
	for position = #candidates, 1, -1 do
		total += candidates[position].factor
		if not finite(total) then
			return nil, "grid-flex-factor-range-provider-required"
		end
		sums[position] = total
	end
	for position, value in candidates do
		WorkQueue.checkpoint()
		local hypothetical = math.max(0, leftover) / math.max(1, sums[position])
		if hypothetical * value.factor < sizes[value.index] then
			leftover -= sizes[value.index]
		else
			return hypothetical, nil
		end
	end
	return 0, nil
end

-- The final three track-sizing phases: maximize, expand fr, and stretch auto.
-- Intrinsic item contributions, placement, and alignment are separate phases.
function GridTrackSizing.finish(tracks: { Track }, context: Context): (Result?, string?)
	if context.constraint ~= nil and context.constraint ~= "min-content" and context.constraint ~= "max-content" then
		return nil, "invalid-grid-sizing-constraint"
	end
	local gap = context.gap or 0
	if not finite(gap) or gap < 0 then
		return nil, "invalid-grid-track-gap"
	end
	local available = context.available
	if available ~= nil and (not finite(available) or available < 0) then
		return nil, "invalid-grid-available-space"
	end
	local sizes = {}
	local extent = math.max(0, #tracks - 1) * gap
	for index, value in tracks do
		WorkQueue.checkpoint()
		if not finite(value.base) or value.base < 0 or not finite(value.limit) or value.limit < value.base then
			return nil, "grid-resolved-intrinsic-track-sizes-required"
		elseif value.flex ~= nil and (not finite(value.flex) or value.flex < 0 or value.stretchable) then
			return nil, "invalid-grid-flex-track-state"
		end
		sizes[index] = value.base
		extent += value.base
	end
	if not finite(extent) then
		return nil, "grid-track-size-range-provider-required"
	end
	if context.constraint ~= "min-content" then
		if available == nil or context.constraint == "max-content" then
			for index, value in tracks do
				if value.flex == nil then
					sizes[index] = value.limit
				end
			end
		elseif available > extent then
			maximize(sizes, tracks, available - extent)
		end
	end
	local usedFraction = 0
	if context.constraint ~= "min-content" then
		if available ~= nil and context.constraint ~= "max-content" then
			local value, failure = fraction(sizes, tracks, 1, #tracks, available, gap)
			if not value then
				return nil, failure
			end
			usedFraction = value
		else
			for index, value in tracks do
				if value.flex ~= nil then
					usedFraction = math.max(usedFraction, sizes[index] / math.max(1, value.flex))
				end
			end
			for _, item in context.contributions or {} do
				if
					item.first < 1
					or item.last < item.first
					or item.last > #tracks
					or item.first % 1 ~= 0
					or item.last % 1 ~= 0
					or not finite(item.maximum)
					or item.maximum < 0
				then
					return nil, "invalid-grid-flex-content-contribution"
				end
				local value, failure = fraction(sizes, tracks, item.first, item.last, item.maximum, gap)
				if not value then
					return nil, failure
				end
				usedFraction = math.max(usedFraction, value)
			end
		end
	end
	extent = math.max(0, #tracks - 1) * gap
	local stretchable = 0
	for index, value in tracks do
		WorkQueue.checkpoint()
		if value.flex ~= nil then
			sizes[index] = math.max(sizes[index], usedFraction * value.flex)
		end
		if value.stretchable then
			stretchable += 1
		end
		extent += sizes[index]
	end
	if not finite(extent) then
		return nil, "grid-track-size-range-provider-required"
	end
	if
		context.constraint ~= "min-content"
		and context.stretch
		and available
		and available > extent
		and stretchable > 0
	then
		local share = (available - extent) / stretchable
		for index, value in tracks do
			if value.stretchable then
				sizes[index] += share
			end
		end
	end
	local offsets = {}
	extent = 0
	for index, value in sizes do
		WorkQueue.checkpoint()
		offsets[index] = extent
		extent += value + (if index < #sizes then gap else 0)
	end
	if not finite(extent) then
		return nil, "grid-track-size-range-provider-required"
	end
	return {
		sizes = sizes,
		offsets = offsets,
		extent = extent,
		remaining = if available then available - extent else nil,
		fraction = usedFraction,
	},
		nil
end

return GridTrackSizing
