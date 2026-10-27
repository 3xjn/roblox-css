--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local ColorSpaces = require(script.Parent.ColorSpaces)
local ColorProfiles = require(script.Parent.ColorProfiles)
type Token = Types.ValueToken

local ColorFunctions = {}

local function channels(token: Token): ({ Token }?, boolean, string?)
	local parts: { Token } = {}
	local legacy = false
	for _, child in token.children or {} do
		if child.kind ~= "space" and child.kind ~= "comment" then
			table.insert(parts, child)
			legacy = legacy or (child.kind == "div" and child.value == ",")
		end
	end
	if legacy then
		if #parts ~= 5 and #parts ~= 7 then
			return nil, true, "invalid-legacy-color-arity"
		end
		local result: { Token } = {}
		for index, part in parts do
			if index % 2 == 0 then
				if part.kind ~= "div" or part.value ~= "," then
					return nil, true, "invalid-legacy-color-separator"
				end
			else
				table.insert(result, part)
			end
		end
		return result, true, nil
	end
	if #parts == 3 then
		return parts, false, nil
	elseif #parts == 5 and parts[4].kind == "operator" and parts[4].value == "/" then
		return { parts[1], parts[2], parts[3], parts[5] }, false, nil
	end
	return nil, false, "unsupported-or-invalid-color-channel-syntax"
end

local function quantity(token: Token): (Measurements.Quantity?, string?)
	if token.kind == "word" and string.lower(token.value) == "none" then
		return nil, "missing-color-component-provider-required"
	end
	local value, failure = Measurements.resolve({ token }, { strictPercentageTypes = true })
	if not value then
		return nil, failure or "color-channel-computation-required"
	end
	if value.value ~= value.value or math.abs(value.value) == math.huge or value.percentage ~= nil then
		return nil, "color-channel-arithmetic-range-required"
	end
	return value, nil
end

-- HSL resolves to gamma-encoded sRGB. Preserve out-of-gamut results for the
-- existing native gamut boundary instead of silently clipping HSL channels.
local function hsl(hue: number, saturation: number, lightness: number): (number, number, number)
	local sector = (hue % 360) / 60
	local chroma = (1 - math.abs(2 * lightness - 1)) * math.max(0, saturation)
	local secondary = chroma * (1 - math.abs(sector % 2 - 1))
	local r, g, b = 0, 0, 0
	if sector < 1 then
		r, g = chroma, secondary
	elseif sector < 2 then
		r, g = secondary, chroma
	elseif sector < 3 then
		g, b = chroma, secondary
	elseif sector < 4 then
		g, b = secondary, chroma
	elseif sector < 5 then
		r, b = secondary, chroma
	else
		r, b = chroma, secondary
	end
	local offset = lightness - chroma / 2
	return r + offset, g + offset, b + offset
end

-- CSS Color 4 HWB conversion. Channels here use 1 for 100%.
-- Keep extended values; gamut mapping belongs to the native display boundary.
local function hwb(hue: number, white: number, black: number): (number, number, number)
	if white + black >= 1 then
		-- Scale before addition so finite, very large channels do not overflow.
		local scale = math.max(math.abs(white), math.abs(black))
		local gray = (white / scale) / (white / scale + black / scale)
		return gray, gray, gray
	end
	local r, g, b = hsl(hue, 1, 0.5)
	local remaining = 1 - white - black
	return r * remaining + white, g * remaining + white, b * remaining + white
end

function ColorFunctions.resolve(token: Token, relative: boolean?): (Types.RgbaColor?, string?)
	local name = string.lower(token.value)
	local rgb = name == "rgb" or name == "rgba"
	local isHsl = name == "hsl" or name == "hsla"
	local isHwb = name == "hwb"
	local isOklab = name == "oklab" or name == "oklch"
	local isLab = name == "lab" or name == "lch"
	local profile: string? = nil
	local source = token
	if name == "color" then
		local content: { Token } = {}
		for _, child in token.children or {} do
			if child.kind ~= "space" and child.kind ~= "comment" then
				table.insert(content, child)
			end
		end
		if not content[1] or content[1].kind ~= "word" then
			return nil, "color-profile-required"
		end
		profile = string.lower(content[1].value)
		if not ColorProfiles[profile] then
			return nil, `color-profile-provider-required:{profile}`
		end
		table.remove(content, 1)
		source = table.clone(token)
		source.children = content
	end
	if not rgb and not isHsl and not isHwb and not isOklab and not isLab and not profile then
		return nil, `unsupported-color-function:{name}`
	end
	local parts, legacy, failure = channels(source)
	if not parts then
		return nil, failure
	end
	if legacy and not rgb and not isHsl then
		return nil, "legacy-syntax-not-allowed-for-color-space"
	end
	local values: { number } = {}
	local rgbType: string? = nil
	for index, part in parts do
		local value, reason = quantity(part)
		if not value then
			return nil, reason
		end
		if index == 4 then
			if value.dimension ~= "number" and value.dimension ~= "percentage" then
				return nil, "color-alpha-number-percentage-required"
			end
			values[4] = math.clamp(value.value, 0, 1)
		elseif ((isHsl or isHwb) and index == 1) or ((name == "oklch" or name == "lch") and index == 3) then
			if value.dimension ~= "angle" and value.dimension ~= "number" then
				return nil, "color-hue-number-angle-required"
			end
			values[index] = value.value
		else
			if value.dimension ~= "percentage" and (value.dimension ~= "number" or (legacy and not rgb)) then
				return nil, "color-channel-number-percentage-required"
			end
			if rgb and legacy and rgbType and rgbType ~= value.dimension then
				return nil, "mixed-legacy-rgb-channel-types"
			end
			rgbType = value.dimension
			local scalar: number
			if isOklab then
				scalar = value.value * (if value.dimension == "percentage" and index ~= 1 then 0.4 else 1)
			elseif isLab then
				scalar = value.value
					* (
						if value.dimension ~= "percentage"
							then 1
							elseif index == 1 then 100
							elseif name == "lch" then 150
							else 125
					)
			elseif profile then
				scalar = value.value
			else
				scalar = if value.dimension == "percentage"
					then value.value
					else value.value / (if rgb then 255 else 100)
			end
			values[index] = if rgb and not relative then math.clamp(scalar, 0, 1) else scalar
		end
	end
	local r, g, b = values[1], values[2], values[3]
	if isHsl then
		r, g, b = hsl(r, g, b)
	elseif isHwb then
		r, g, b = hwb(r, g, b)
	elseif isOklab or isLab then
		if not relative then
			r = math.clamp(r, 0, if isLab then 100 else 1)
		end
		if name == "oklch" or name == "lch" then
			local chroma, hue = if relative then g else math.max(0, g), math.rad(b % 360)
			g, b = chroma * math.cos(hue), chroma * math.sin(hue)
		end
		if isLab then
			r, g, b = ColorSpaces.fromLab(r, g, b)
		else
			r, g, b = ColorSpaces.fromOklab(r, g, b)
		end
	elseif profile then
		r, g, b = ColorProfiles[profile](r, g, b)
	end
	for _, channel in { r, g, b } do
		if channel ~= channel or math.abs(channel) == math.huge then
			return nil, "color-channel-arithmetic-range-required"
		end
	end
	return { r = r, g = g, b = b, alpha = values[4] or 1 }, nil
end

return ColorFunctions
