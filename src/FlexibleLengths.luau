--!strict

-- CSS Flexbox 1, section 9.7. Inputs are measured outer flex bases; padding and
-- borders stay separate because shrink weighting uses the inner flex base.
export type Item = {
	base: number,
	inset: number,
	minimum: number,
	maximum: number?,
	margin: number,
	grow: number,
	shrink: number,
}
type Working = { input: Item, hypothetical: number, target: number, frozen: boolean, violation: number }

local FlexibleLengths = {}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function bounded(item: Item, value: number): number
	return math.max(item.inset, item.minimum, math.min(value, item.maximum or math.huge))
end

function FlexibleLengths.resolve(items: { Item }, available: number, gap: number): ({ number }?, string?)
	if not finite(available) or available < 0 or not finite(gap) or gap < 0 then
		return nil, "invalid-flex-length-budget"
	end
	local work: { Working } = {}
	local gutters = gap * math.max(0, #items - 1)
	local hypotheticalTotal = gutters
	for _, item in items do
		for _, value in { item.base, item.inset, item.minimum, item.grow, item.shrink } do
			if not finite(value) or value < 0 then
				return nil, "invalid-flex-length-input"
			end
		end
		if not finite(item.margin) or (item.maximum ~= nil and (not finite(item.maximum) or item.maximum < 0)) then
			return nil, "invalid-flex-length-input"
		end
		local hypothetical = bounded(item, item.base)
		hypotheticalTotal += hypothetical + item.margin
		table.insert(
			work,
			{ input = item, hypothetical = hypothetical, target = item.base, frozen = false, violation = 0 }
		)
	end
	if not finite(hypotheticalTotal) or not finite(gutters) then
		return nil, "nonfinite-flex-budget"
	end
	local growing = hypotheticalTotal < available
	for _, item in work do
		local factor = if growing then item.input.grow else item.input.shrink
		if
			factor == 0
			or (growing and item.input.base > item.hypothetical)
			or (not growing and item.input.base < item.hypothetical)
		then
			item.target = item.hypothetical
			item.frozen = true
		end
	end
	local function freeSpace(): number
		local used = gutters
		for _, item in work do
			used += (if item.frozen then item.target else item.input.base) + item.input.margin
		end
		return available - used
	end
	local initialFree = freeSpace()
	if not finite(initialFree) then
		return nil, "nonfinite-flex-budget"
	end
	-- Every pass freezes at least one item. This is a bounded numeric algorithm,
	-- with no timers, frame callbacks or retries.
	for _ = 1, #work do
		local count, factorSum, largestFactor, largestInner = 0, 0, 0, 0
		for _, item in work do
			if not item.frozen then
				count += 1
				local factor = if growing then item.input.grow else item.input.shrink
				factorSum += factor
				largestFactor = math.max(largestFactor, factor)
				largestInner = math.max(largestInner, item.input.base - item.input.inset)
			end
		end
		if count == 0 then
			break
		end
		local remaining = freeSpace()
		if factorSum < 1 then
			local fractional = initialFree * factorSum
			if math.abs(fractional) < math.abs(remaining) then
				remaining = fractional
			end
		end
		if not finite(remaining) then
			return nil, "nonfinite-flex-budget"
		end
		-- Normalize each factor before multiplying, so large valid factors and
		-- bases cannot overflow the proportional-weight calculation.
		local function weight(item: Working): number
			if largestFactor == 0 then
				return 0
			end
			if growing then
				return item.input.grow / largestFactor
			end
			if largestInner <= 0 then
				return 0
			end
			return (item.input.shrink / largestFactor) * math.max(0, item.input.base - item.input.inset) / largestInner
		end
		local weightSum = 0
		for _, item in work do
			if not item.frozen then
				weightSum += weight(item)
			end
		end
		local totalViolation = 0
		for _, item in work do
			if not item.frozen then
				local target = item.input.base
				if remaining ~= 0 and weightSum > 0 then
					local share = weight(item) / weightSum
					target += if growing then remaining * share else -math.abs(remaining) * share
				end
				if not finite(target) then
					return nil, "nonfinite-flex-target"
				end
				item.target = bounded(item.input, target)
				item.violation = item.target - target
				totalViolation += item.violation
			end
		end
		if not finite(totalViolation) then
			return nil, "nonfinite-flex-violation"
		end
		local frozen = 0
		for _, item in work do
			if
				not item.frozen
				and (
					totalViolation == 0
					or totalViolation > 0 and item.violation > 0
					or totalViolation < 0 and item.violation < 0
				)
			then
				item.frozen = true
				frozen += 1
			end
		end
		if frozen == 0 then
			return nil, "flex-length-resolution-stalled"
		end
	end
	local result = {}
	for _, item in work do
		if not item.frozen then
			return nil, "flex-length-resolution-incomplete"
		end
		table.insert(result, item.target)
	end
	return result, nil
end

return FlexibleLengths
