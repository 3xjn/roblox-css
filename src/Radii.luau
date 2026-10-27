--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)

export type Radius = { x: number, y: number }
export type Corners = { topLeft: Radius, topRight: Radius, bottomRight: Radius, bottomLeft: Radius }

local Radii = {}
local names = { "top-left", "top-right", "bottom-right", "bottom-left" }
local radiusRange: Measurements.MathRange = table.freeze({ minimum = 0 })

local function axis(token: Types.ValueToken, basis: number, lengths: Measurements.Context): (number?, string?)
	local options = table.clone(lengths)
	options.allowRatio = nil
	options.percentageDimension = "length"
	options.percentageBasis = basis
	options.mathRange = radiusRange
	local measured, failure = Measurements.resolve({ token }, options)
	if not measured then
		return nil, failure
	end
	if measured.dimension == "number" and measured.value == 0 then
		return 0, nil
	end
	if measured.dimension ~= "length" then
		return nil, "radius-length-required"
	end
	local value = Measurements.toScalar(measured, options)
	if value == nil then
		return nil, "radius-basis-required"
	end
	if value ~= value or math.abs(value) == math.huge then
		return nil, "nonfinite-radius"
	end
	if value < 0 then
		if token.kind == "function" then
			return 0, nil
		end
		return nil, "negative-radius"
	end
	return value, nil
end

-- CSS Backgrounds 3: percentages use the corresponding border-box dimension,
-- then every radius shares one overlap-reduction factor.
function Radii.resolve(
	style: Types.ComputedStyle,
	width: number,
	height: number,
	lengths: Measurements.Context
): (Corners?, string?)
	if width < 0 or height < 0 or width ~= width or height ~= height or width == math.huge or height == math.huge then
		return nil, "invalid-radius-box"
	end
	local radii: { Radius } = {}
	for _, name in names do
		local property = `border-{name}-radius`
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
		local parts: { Types.ValueToken } = {}
		for _, token in style.properties[property] or {} do
			if token.kind ~= "space" and token.kind ~= "comment" then
				table.insert(parts, token)
			end
		end
		if #parts == 0 then
			table.insert(radii, { x = 0, y = 0 })
			continue
		end
		if #parts > 2 then
			return nil, `{property}:invalid-radius-pair`
		end
		local x, xFailure = axis(parts[1], width, lengths)
		local y, yFailure = axis(parts[2] or parts[1], height, lengths)
		if x == nil or y == nil then
			return nil, `{property}:{xFailure or yFailure or "invalid"}`
		end
		table.insert(radii, { x = x, y = y })
	end
	local scale = 1
	local underflow = false
	local function fit(dimension: number, a: number, b: number)
		local maximum = math.max(a, b)
		if maximum > 0 then
			-- Normalize before adding so two finite radii cannot overflow.
			local ratio = (dimension / maximum) / (a / maximum + b / maximum)
			underflow = underflow or (ratio == 0 and dimension > 0)
			scale = math.min(scale, ratio)
		end
	end
	fit(width, radii[1].x, radii[2].x)
	fit(width, radii[4].x, radii[3].x)
	fit(height, radii[1].y, radii[4].y)
	fit(height, radii[2].y, radii[3].y)
	if underflow then
		-- Keep the common factor as a mantissa/exponent pair until applying
		-- each radius. Targets that flush subnormals must not turn it into zero.
		local mantissa, exponent = 0.5, 1 -- one
		local zero = false
		local function fitNormalized(dimension: number, a: number, b: number)
			local maximum = math.max(a, b)
			if maximum == 0 then return end
			if dimension == 0 then
				zero = true
				return
			end
			local dm, de = math.frexp(dimension)
			local rm, re = math.frexp(maximum)
			local fm, fe = math.frexp((dm / rm) / (a / maximum + b / maximum))
			local candidate = de - re + fe
			if candidate < exponent or (candidate == exponent and fm < mantissa) then
				mantissa, exponent = fm, candidate
			end
		end
		fitNormalized(width, radii[1].x, radii[2].x)
		fitNormalized(width, radii[4].x, radii[3].x)
		fitNormalized(height, radii[1].y, radii[4].y)
		fitNormalized(height, radii[2].y, radii[3].y)
		for _, radius in radii do
			local xm, xe = math.frexp(radius.x)
			local ym, ye = math.frexp(radius.y)
			radius.x = if zero then 0 else math.ldexp(xm * mantissa, xe + exponent)
			radius.y = if zero then 0 else math.ldexp(ym * mantissa, ye + exponent)
		end
		return { topLeft = radii[1], topRight = radii[2], bottomRight = radii[3], bottomLeft = radii[4] }, nil
	end
	for _, radius in radii do
		radius.x *= scale
		radius.y *= scale
	end
	return { topLeft = radii[1], topRight = radii[2], bottomRight = radii[3], bottomLeft = radii[4] }, nil
end

return Radii
