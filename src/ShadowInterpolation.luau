--!strict

local ShadowPaint = require(script.Parent.ShadowPaint)
local ColorSpaces = require(script.Parent.ColorSpaces)
type Shadow = ShadowPaint.Shadow
local ShadowInterpolation = {}
local function empty(inset: boolean): Shadow
	return { x = 0, y = 0, blur = 0, spread = 0, inset = inset, color = { r = 0, g = 0, b = 0, alpha = 0 } }
end
function ShadowInterpolation.pair(a: { Shadow }, b: { Shadow }): ({ Shadow }?, { Shadow }?)
	local left: { Shadow } = {}
	local right: { Shadow } = {}
	for index = 1, math.max(#a, #b) do
		local x, y = a[index], b[index]
		if x and y and x.inset ~= y.inset then
			return nil, nil
		end
		table.insert(left, x or empty(y.inset))
		table.insert(right, y or empty(x.inset))
	end
	return left, right
end
function ShadowInterpolation.equal(a: { Shadow }, b: { Shadow }): boolean
	if #a ~= #b then
		return false
	end
	for i, x in a do
		local y = b[i]
		if x.x ~= y.x or x.y ~= y.y or x.blur ~= y.blur or x.spread ~= y.spread or x.inset ~= y.inset then
			return false
		end
		if
			x.color.r ~= y.color.r
			or x.color.g ~= y.color.g
			or x.color.b ~= y.color.b
			or x.color.alpha ~= y.color.alpha
		then
			return false
		end
	end
	return true
end
function ShadowInterpolation.sample(a: { Shadow }, b: { Shadow }, p: number): { Shadow }
	if p <= 0 then
		return a
	elseif p >= 1 then
		return b
	end
	local result: { Shadow } = {}
	local function lerp(x: number, y: number): number
		return x + (y - x) * p
	end
	for index, x in a do
		local y = b[index]
		local alpha = lerp(x.color.alpha, y.color.alpha)
		local ar, ag, ab = ColorSpaces.toOklab(x.color.r, x.color.g, x.color.b)
		local br, bg, bb = ColorSpaces.toOklab(y.color.r, y.color.g, y.color.b)
		local function channel(l: number, r: number): number
			return if alpha == 0 then 0 else lerp(l * x.color.alpha, r * y.color.alpha) / alpha
		end
		local r, g, blue = ColorSpaces.fromOklab(channel(ar, br), channel(ag, bg), channel(ab, bb))
		table.insert(
			result,
			{
				x = lerp(x.x, y.x),
				y = lerp(x.y, y.y),
				blur = math.max(0, lerp(x.blur, y.blur)),
				spread = lerp(x.spread, y.spread),
				inset = x.inset,
				color = { r = r, g = g, b = blue, alpha = math.clamp(alpha, 0, 1) },
			}
		)
	end
	return result
end
return ShadowInterpolation
