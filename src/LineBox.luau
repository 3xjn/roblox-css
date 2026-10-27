--!strict

-- All values are CSS pixels supplied by authoritative font metrics. Native
-- TextBounds does not provide ascent/descent and must not be substituted here.
export type Metrics = { ascent: number, descent: number, lineHeight: number }
export type Run = { metrics: Metrics, shift: number? }
export type Placement = { baseline: number, top: number, bottom: number }
export type Result = { height: number, baseline: number, runs: { Placement } }

local LineBox = {}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function extents(metrics: Metrics): (number?, number?, string?)
	for _, value in { metrics.ascent, metrics.descent, metrics.lineHeight } do
		if not finite(value) or value < 0 then
			return nil, nil, "invalid-line-box-metrics"
		end
	end
	local leading = (metrics.lineHeight - metrics.ascent - metrics.descent) / 2
	local above, below = metrics.ascent + leading, metrics.descent + leading
	if not finite(above) or not finite(below) then
		return nil, nil, "line-box-metrics-overflow"
	end
	return above, below, nil
end

-- Alphabetic baseline alignment, including negative half-leading and explicit
-- baseline shifts. Top/bottom alignment and deciding whether a phantom/empty
-- line exists belong to the inline formatting provider.
function LineBox.resolve(strut: Metrics, runs: { Run }): (Result?, string?)
	local above, below, failure = extents(strut)
	if above == nil or below == nil then
		return nil, failure
	end
	local ascents: { number } = {}
	for index, run in runs do
		local ascent, descent, reason = extents(run.metrics)
		if ascent == nil or descent == nil then
			return nil, reason
		end
		local shift = run.shift or 0
		if not finite(shift) then
			return nil, "invalid-line-box-baseline-shift"
		end
		ascents[index] = ascent
		above = math.max(above, ascent + shift)
		below = math.max(below, descent - shift)
	end
	if not finite(above) or not finite(below) or not finite(above + below) then
		return nil, "line-box-geometry-overflow"
	end
	local placements: { Placement } = {}
	for index, run in runs do
		local baseline = above - (run.shift or 0)
		local top = baseline - ascents[index]
		local bottom = top + run.metrics.lineHeight
		if not finite(baseline) or not finite(top) or not finite(bottom) then
			return nil, "line-box-placement-overflow"
		end
		table.insert(placements, { baseline = baseline, top = top, bottom = bottom })
	end
	return { height = math.max(0, above + below), baseline = above, runs = placements }, nil
end

return LineBox
