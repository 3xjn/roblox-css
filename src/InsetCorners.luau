--!strict

local NativeDimensions = require(script.Parent.NativeDimensions)

export type Corners = { topLeft: number, topRight: number, bottomLeft: number, bottomRight: number }
export type Context = {
	width: number,
	height: number,
	x: number,
	y: number,
	innerWidth: number,
	innerHeight: number,
	corners: Corners?,
	perCornerRadius: boolean?,
}
export type Encoded = { radii: { [string]: UDim }, individual: boolean }

local InsetCorners = {}

local function nonnegative(value: number): boolean
	return value >= 0 and value < math.huge
end

-- Shared inset-edge geometry: subtract each actual axis inset from the
-- outer corner before deciding whether native circular paint is possible.
function InsetCorners.resolve(context: Context): (Encoded?, string?)
	local outer = context.corners
	if not outer then
		return nil, nil
	end
	local geometry = context
	local left, top = geometry.x, geometry.y
	local right = geometry.width - left - geometry.innerWidth
	local bottom = geometry.height - top - geometry.innerHeight
	for _, value in { left, right, top, bottom, geometry.innerWidth, geometry.innerHeight } do
		if not nonnegative(value) then
			return nil, "invalid-inset-clip-geometry"
		end
	end
	local insets: { [string]: { number } } = {
		topLeft = { left, top },
		topRight = { right, top },
		bottomLeft = { left, bottom },
		bottomRight = { right, bottom },
	}
	local values: { [string]: number } = {}
	local maximum = math.min(geometry.innerWidth, geometry.innerHeight) / 2
	local positive = false
	for name, pair in insets do
		local radius = (outer :: { [string]: number })[name]
		if not nonnegative(radius) then
			return nil, "invalid-inset-clip-radius"
		end
		local x, y = math.max(0, radius - pair[1]), math.max(0, radius - pair[2])
		local inner: number
		if x == 0 or y == 0 then
			inner = 0
		elseif x == y then
			inner = x
		else
			return nil, "elliptical-inset-clip-provider-required"
		end
		if inner > maximum then
			return nil, "native-inset-radius-clamping-differs"
		end
		values[name] = inner
		positive = positive or inner > 0
	end
	if not positive then
		return nil, nil
	end
	local individual = values.topLeft ~= values.topRight
		or values.topLeft ~= values.bottomLeft
		or values.topLeft ~= values.bottomRight
	if individual and not context.perCornerRadius then
		return nil, "native-inset-per-corner-radius-unavailable"
	end
	local radii: { [string]: UDim } = {}
	for name, value in values do
		local encoded, failure = NativeDimensions.axis(value, maximum * 2)
		if not encoded then
			return nil, failure
		end
		radii[name] = encoded
	end
	return { radii = radii, individual = individual }, nil
end

return InsetCorners
