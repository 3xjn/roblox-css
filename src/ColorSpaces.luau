--!strict

-- Conversion formulas adapted from Culori 4.0.2. See LICENSE.culori.
-- https://github.com/Evercoder/culori/tree/v4.0.2/src

local ColorSpaces = {}

local function linear(value: number): number
	local magnitude = math.abs(value)
	return if magnitude <= 0.04045 then value / 12.92 else math.sign(value) * ((magnitude + 0.055) / 1.055) ^ 2.4
end

local function gamma(value: number): number
	local magnitude = math.abs(value)
	return if magnitude <= 0.0031308 then value * 12.92 else math.sign(value) * (1.055 * magnitude ^ (1 / 2.4) - 0.055)
end

local function cbrt(value: number): number
	return math.sign(value) * math.abs(value) ^ (1 / 3)
end

function ColorSpaces.toLinear(r: number, g: number, b: number): (number, number, number)
	return linear(r), linear(g), linear(b)
end

function ColorSpaces.fromLinear(r: number, g: number, b: number): (number, number, number)
	return gamma(r), gamma(g), gamma(b)
end

function ColorSpaces.toOklab(r: number, g: number, b: number): (number, number, number)
	r, g, b = ColorSpaces.toLinear(r, g, b)
	local l = cbrt(0.412221469470763 * r + 0.5363325372617348 * g + 0.0514459932675022 * b)
	local m = cbrt(0.2119034958178252 * r + 0.6806995506452344 * g + 0.1073969535369406 * b)
	local s = cbrt(0.0883024591900564 * r + 0.2817188391361215 * g + 0.6299787016738222 * b)
	return 0.210454268309314 * l + 0.7936177747023054 * m - 0.0040720430116193 * s,
		1.9779985324311684 * l - 2.4285922420485799 * m + 0.450593709617411 * s,
		0.0259040424655478 * l + 0.7827717124575296 * m - 0.8086757549230774 * s
end

function ColorSpaces.fromOklab(l: number, a: number, b: number): (number, number, number)
	local ll = (l + 0.3963377773761749 * a + 0.2158037573099136 * b) ^ 3
	local mm = (l - 0.1055613458156586 * a - 0.0638541728258133 * b) ^ 3
	local ss = (l - 0.0894841775298119 * a - 1.2914855480194092 * b) ^ 3
	return ColorSpaces.fromLinear(
		4.0767416360759574 * ll - 3.3077115392580616 * mm + 0.2309699031821044 * ss,
		-1.2684379732850317 * ll + 2.6097573492876887 * mm - 0.3413193760026573 * ss,
		-0.0041960761386756 * ll - 0.7034186179359362 * mm + 1.7076146940746117 * ss
	)
end

-- Matrices, D50 white point and Lab constants follow Culori 4.0.2's
-- xyz65/convertXyz65ToRgb.js, xyz65/convertXyz50ToXyz65.js and
-- lab/convertLabToXyz50.js (same MIT notice as the Oklab conversions above).
function ColorSpaces.fromXyz65(x: number, y: number, z: number): (number, number, number)
	return ColorSpaces.fromLinear(
		x * 3.2409699419045226 - y * 1.5373831775700939 - z * 0.4986107602930034,
		x * -0.9692436362808796 + y * 1.8759675015077204 + z * 0.0415550574071756,
		x * 0.0556300796969936 - y * 0.2039769588889765 + z * 1.0569715142428784
	)
end

function ColorSpaces.fromXyz50(x: number, y: number, z: number): (number, number, number)
	return ColorSpaces.fromXyz65(
		0.9554734527042182 * x - 0.0230985368742614 * y + 0.0632593086610217 * z,
		-0.0283697069632081 * x + 1.0099954580058226 * y + 0.021041398966943 * z,
		0.0123140016883199 * x - 0.0205076964334779 * y + 1.3303659366080753 * z
	)
end

function ColorSpaces.fromLab(l: number, a: number, b: number): (number, number, number)
	local fy = (l + 16) / 116
	local function axis(value: number): number
		local cube = value ^ 3
		return if cube > (6 / 29) ^ 3 then cube else (116 * value - 16) / ((29 / 3) ^ 3)
	end
	return ColorSpaces.fromXyz50(
		axis(a / 500 + fy) * (0.3457 / 0.3585),
		axis(fy),
		axis(fy - b / 200) * ((1 - 0.3457 - 0.3585) / 0.3585)
	)
end

-- Culori 4.0.2 xyz50/convertRgbToXyz50.js and lab/convertXyz50ToLab.js.
function ColorSpaces.toLab(r: number, g: number, b: number): (number, number, number)
	r, g, b = ColorSpaces.toLinear(r, g, b)
	local x = 0.436065742824811 * r + 0.3851514688337912 * g + 0.14307845442264197 * b
	local y = 0.22249319175623702 * r + 0.7168870538238823 * g + 0.06061979053616537 * b
	local z = 0.013923904500943465 * r + 0.09708128566574634 * g + 0.7140993584005155 * b
	local function axis(value: number): number
		return if value > (6 / 29) ^ 3 then cbrt(value) else (((29 / 3) ^ 3) * value + 16) / 116
	end
	local fx = axis(x / (0.3457 / 0.3585))
	local fy = axis(y)
	local fz = axis(z / ((1 - 0.3457 - 0.3585) / 0.3585))
	return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)
end

return ColorSpaces
