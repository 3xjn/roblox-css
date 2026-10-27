--!strict

local NativeDimensions = {}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function represents(actual: number, expected: number): boolean
	return finite(actual) and math.abs(actual - expected) <= math.max(1, math.abs(expected)) * 1e-6
end

-- The transparent out-of-flow carrier can have a nonzero native reference
-- without changing its owner's CSS content box. Preserve every positive axis,
-- including subpixel extents; only a zero axis needs a representation surface.
function NativeDimensions.overlayReference(reference: Vector2): Vector2
	if reference.X ~= 0 and reference.Y ~= 0 then
		return reference
	end
	return Vector2.new(if reference.X == 0 then 1 else reference.X, if reference.Y == 0 then 1 else reference.Y)
end

-- UDim offsets are integers. Scale carries the fractional remainder using the
-- caller's logical reference size, never a guessed or screen-scaled size.
function NativeDimensions.axis(value: number, reference: number?): (UDim?, string?)
	if not finite(value) then
		return nil, "nonfinite-native-dimension"
	end
	local offset = math.floor(value)
	if offset < -2147483648 or offset > 2147483647 then
		offset = 0
	end
	local remainder = value - offset
	if remainder == 0 then
		return UDim.new(0, offset), nil
	end
	if not reference or not finite(reference) or reference <= 0 then
		-- A computed length can land an ulp away from an integer (for example
		-- accumulated line heights inside a zero-height content box). An offset
		-- within the same error budget as scale encoding needs no reference.
		local nearest = math.floor(value + 0.5)
		if nearest >= -2147483648 and nearest <= 2147483647 and represents(nearest, value) then
			return UDim.new(0, nearest), nil
		end
		return nil, "fractional-native-dimension-reference-required"
	end
	local scale = remainder / reference
	if not finite(scale) then
		return nil, "native-dimension-not-representable"
	end
	local result = UDim.new(scale, offset)
	local actual = result.Scale * reference + result.Offset
	if not represents(actual, value) then
		return nil, "native-dimension-not-representable"
	end
	return result, nil
end

function NativeDimensions.pair(x: number, y: number, reference: Vector2?): (UDim2?, string?)
	-- Whole offsets need no fractional encoding or intermediate UDim values.
	-- The range checks also exclude nonfinite inputs; all other cases retain
	-- axis conversion and its reference/representability checks below.
	if x >= -2147483648 and x <= 2147483647 and y >= -2147483648 and y <= 2147483647 and x % 1 == 0 and y % 1 == 0 then
		return UDim2.fromOffset(x, y), nil
	end
	local horizontal, xFailure = NativeDimensions.axis(x, if reference then reference.X else nil)
	local vertical, yFailure = NativeDimensions.axis(y, if reference then reference.Y else nil)
	if not horizontal or not vertical then
		return nil, xFailure or yFailure
	end
	return UDim2.new(horizontal.Scale, horizontal.Offset, vertical.Scale, vertical.Offset), nil
end

return NativeDimensions
