--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)

export type Context = {
	lengths: Measurements.Context,
	-- Nearest block container's shaped space advance, including its associated
	-- word/letter spacing, supplied by the font/layout provider.
	spaceAdvance: number?,
}

local Tabs = {}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

function Tabs.resolveInterval(style: Types.ComputedStyle, context: Context): (number?, string?)
	if style.unresolved["tab-size"] then
		return nil, `tab-size:{style.unresolved["tab-size"]}`
	end
	local tokens: { Types.ValueToken } = style.properties["tab-size"] or { { kind = "number", value = "8" } }
	local options = table.clone(context.lengths)
	options.allowRatio, options.percentageBasis, options.percentageDimension = nil, nil, nil
	local measured, failure = Measurements.resolve(tokens, options)
	if not measured then
		return nil, failure
	end
	local value = measured.value
	if value < 0 and #tokens == 1 and tokens[1].kind == "function" then
		value = 0
	end
	if value < 0 or (measured.percentage or 0) ~= 0 then
		return nil, "invalid-tab-size"
	end
	if measured.dimension == "number" then
		if value == 0 then
			return 0, nil
		end
		local advance = context.spaceAdvance
		if advance == nil then
			return nil, "tab-container-space-advance-required"
		end
		if not finite(advance) or advance < 0 then
			return nil, "invalid-tab-container-space-advance"
		end
		value *= advance
	elseif measured.dimension ~= "length" then
		return nil, "tab-size-number-or-length-required"
	end
	if not finite(value) then
		return nil, "tab-interval-overflow"
	end
	return value, nil
end

-- Position is the logical inline distance from the nearest block container's
-- starting content edge. Negative positions (e.g. negative text-indent) work
-- on the same stop grid. minimumGap is the authoritative 0.5ch distance.
function Tabs.advance(position: number, interval: number, minimumGap: number?): (number?, string?)
	if not finite(position) or not finite(interval) or interval < 0 then
		return nil, "invalid-tab-geometry"
	end
	if interval == 0 then
		return 0, nil
	end
	if minimumGap == nil then
		return nil, "tab-half-ch-metric-required"
	end
	if not finite(minimumGap) or minimumGap < 0 then
		return nil, "invalid-tab-minimum-gap"
	end
	local advance = interval - position % interval
	if advance < minimumGap then
		-- CSS selects the subsequent stop once.
		advance += interval
	end
	local target = position + advance
	if not finite(advance) or not finite(target) or target <= position then
		return nil, "tab-stop-not-representable"
	end
	return advance, nil
end

return Tabs
