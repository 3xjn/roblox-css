--!strict

local ColorSpaces = require(script.Parent.ColorSpaces)
type Convert = (number, number, number) -> (number, number, number)

-- P3 matrix from Culori 4.0.2 src/p3/convertP3ToXyz65.js (MIT;
-- see LICENSE.culori). Linear P3 uses that matrix without the transfer curve.
local function linearP3(r: number, g: number, b: number): (number, number, number)
	return ColorSpaces.fromXyz65(
		0.486570948648216 * r + 0.265667693169093 * g + 0.1982172852343625 * b,
		0.2289745640697487 * r + 0.6917385218365062 * g + 0.079286914093745 * b,
		0.0451133818589026 * g + 1.043944368900976 * b
	)
end

local profiles: { [string]: Convert } = {
	srgb = function(r, g, b)
		return r, g, b
	end,
	["srgb-linear"] = ColorSpaces.fromLinear,
	["display-p3-linear"] = linearP3,
	["display-p3"] = function(r, g, b)
		return linearP3(ColorSpaces.toLinear(r, g, b))
	end,
	xyz = ColorSpaces.fromXyz65,
	["xyz-d65"] = ColorSpaces.fromXyz65,
	["xyz-d50"] = ColorSpaces.fromXyz50,
}

return profiles
