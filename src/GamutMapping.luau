--!strict

-- CSS Color 4 binary search with local MINDE, using the existing Culori-based
-- color-space conversions. Related upstream implementation: Culori 4.0.2
-- src/clamp.js, toGamut (MIT; see LICENSE.culori).
local Types = require(script.Parent.Types)
local ColorSpaces = require(script.Parent.ColorSpaces)
type Color = Types.RgbaColor

local GamutMapping = {}
local jnd, epsilon = 0.02, 0.0001

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function inside(r: number, g: number, b: number): boolean
	return r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1
end

local function result(r: number, g: number, b: number, alpha: number): Color
	return { r = r, g = g, b = b, alpha = alpha }
end

local function distance(l: number, a: number, b: number, clipped: Color): number
	local ll, aa, bb = ColorSpaces.toOklab(clipped.r, clipped.g, clipped.b)
	local dl, da, db = l - ll, a - aa, b - bb
	local largest = math.max(math.abs(dl), math.abs(da), math.abs(db))
	return if largest == 0 then 0 else largest * math.sqrt((dl / largest) ^ 2 + (da / largest) ^ 2 + (db / largest) ^ 2)
end

function GamutMapping.srgb(color: Color): (Color?, string?)
	for _, channel in { color.r, color.g, color.b, color.alpha } do
		if not finite(channel) then
			return nil, "nonfinite-display-color"
		end
	end
	if color.alpha < 0 or color.alpha > 1 then
		return nil, "invalid-display-color-alpha"
	end
	if inside(color.r, color.g, color.b) then
		return table.clone(color), nil
	end
	local l, a, b = ColorSpaces.toOklab(color.r, color.g, color.b)
	if not finite(l) or not finite(a) or not finite(b) then
		return nil, "gamut-mapping-arithmetic-range-required"
	elseif l >= 1 then
		return result(1, 1, 1, color.alpha), nil
	elseif l <= 0 then
		return result(0, 0, 0, color.alpha), nil
	end
	local clipped = result(math.clamp(color.r, 0, 1), math.clamp(color.g, 0, 1), math.clamp(color.b, 0, 1), color.alpha)
	local delta = distance(l, a, b, clipped)
	if not finite(delta) then
		return nil, "gamut-mapping-arithmetic-range-required"
	elseif delta < jnd then
		return clipped, nil
	end
	local largest = math.max(math.abs(a), math.abs(b))
	local chroma = if largest == 0 then 0 else largest * math.sqrt((a / largest) ^ 2 + (b / largest) ^ 2)
	if not finite(chroma) then
		return nil, "gamut-mapping-arithmetic-range-required"
	end
	local unitA, unitB = if chroma > 0 then a / chroma else 0, if chroma > 0 then b / chroma else 0
	local low, high = 0, chroma
	local lowInside = true
	-- A bounded numerical solve, not a native-state check or a recurring task.
	-- Extreme inputs that cannot converge within this budget stay explicit.
	for _ = 1, 64 do
		if high - low <= epsilon then
			return clipped, nil
		end
		local current = low + (high - low) / 2
		if current == low or current == high then
			return nil, "gamut-mapping-convergence-required"
		end
		local aa, bb = unitA * current, unitB * current
		local r, g, blue = ColorSpaces.fromOklab(l, aa, bb)
		if not finite(r) or not finite(g) or not finite(blue) then
			return nil, "gamut-mapping-arithmetic-range-required"
		end
		if lowInside and inside(r, g, blue) then
			low = current
			continue
		end
		clipped = result(math.clamp(r, 0, 1), math.clamp(g, 0, 1), math.clamp(blue, 0, 1), color.alpha)
		delta = distance(l, aa, bb, clipped)
		if not finite(delta) then
			return nil, "gamut-mapping-arithmetic-range-required"
		elseif delta < jnd then
			if jnd - delta < epsilon then
				return clipped, nil
			end
			lowInside = false
			low = current
		else
			high = current
		end
	end
	return if high - low <= epsilon then clipped else nil,
		if high - low <= epsilon then nil else "gamut-mapping-convergence-required"
end

return GamutMapping
