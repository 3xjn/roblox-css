--!strict

local Types = require(script.Parent.Types)
local ColorSpaces = require(script.Parent.ColorSpaces)
local ColorFunctions = require(script.Parent.ColorFunctions)
type Token = Types.ValueToken
type Color = Types.RgbaColor

local RelativeColors = {}
local function number(value: number): Token
	return { kind = "number", value = string.format("%.17g", value) }
end

function RelativeColors.resolve(token: Token, origin: (Token) -> (Color?, string?)): (Color?, string?, boolean)
	local parts: { Token } = {}
	for _, child in token.children or {} do
		if child.kind ~= "space" and child.kind ~= "comment" then
			table.insert(parts, child)
		end
	end
	if not parts[1] or parts[1].kind ~= "word" or string.lower(parts[1].value) ~= "from" then
		return nil, nil, false
	end
	local name = string.lower(token.value)
	local profile: string? = nil
	local start = 3
	if name == "color" then
		if not parts[3] or parts[3].kind ~= "word" then
			return nil, "relative-color-profile-required", true
		end
		profile = string.lower(parts[3].value)
		start = 4
	end
	local count = start + 2
	if
		#parts ~= count
		and (#parts ~= count + 2 or parts[count + 1].kind ~= "operator" or parts[count + 1].value ~= "/")
	then
		return nil, "invalid-relative-color-arguments", true
	end
	local supported = name == "rgb"
		or name == "rgba"
		or name == "lab"
		or name == "lch"
		or name == "oklab"
		or name == "oklch"
		or (name == "color" and (profile == "srgb" or profile == "srgb-linear"))
	if not supported then
		return nil, "relative-color-space-provider-required:" .. (profile or name), true
	end
	-- The compiler may attach an RGBA convenience value to a color containing
	-- none. That representation cannot preserve missing-component provenance.
	local originBudget = 512
	local inspect: (Token) -> string?
	inspect = function(input: Token): string?
		originBudget -= 1
		if originBudget < 0 then
			return "relative-color-expression-budget-provider-required"
		end
		if input.kind == "word" and string.lower(input.value) == "none" then
			return "missing-color-component-provider-required"
		end
		for _, child in input.children or {} do
			local reason = inspect(child)
			if reason then
				return reason
			end
		end
		return nil
	end
	local originFailure = inspect(parts[2])
	if originFailure then
		return nil, originFailure, true
	end
	local base, failure = origin(parts[2])
	if not base then
		return nil, failure or "relative-origin-color-required", true
	end
	local x, y, z = base.r, base.g, base.b
	local keys = { "r", "g", "b" }
	local powerlessHue = false
	if name == "rgb" or name == "rgba" then
		x, y, z = x * 255, y * 255, z * 255
	elseif name == "color" then
		if profile == "srgb-linear" then
			x, y, z = ColorSpaces.toLinear(x, y, z)
		end
	else
		if name == "lab" or name == "lch" then
			x, y, z = ColorSpaces.toLab(x, y, z)
		else
			x, y, z = ColorSpaces.toOklab(x, y, z)
		end
		keys = { "l", "a", "b" }
		if name == "lch" or name == "oklch" then
			local scale = math.max(math.abs(y), math.abs(z))
			local chroma = if scale == 0 then 0 else scale * math.sqrt((y / scale) ^ 2 + (z / scale) ^ 2)
			-- Missing/powerless hue metadata cannot be carried by the RGBA model.
			-- Do not invent a hue for an achromatic origin.
			powerlessHue = chroma < 1e-7
			y, z = chroma, math.deg(math.atan2(z, y)) % 360
			keys = { "l", "c", "h" }
		end
	end
	local channels: { [string]: number } = { [keys[1]] = x, [keys[2]] = y, [keys[3]] = z, alpha = base.alpha }
	for _, value in channels do
		if value ~= value or math.abs(value) == math.huge then
			return nil, "relative-color-conversion-range-required", true
		end
	end
	local budget = 512
	local replace: (Token) -> (Token?, string?)
	replace = function(input: Token): (Token?, string?)
		budget -= 1
		if budget < 0 then
			return nil, "relative-color-expression-budget-provider-required"
		end
		if input.kind == "word" then
			local keyword = string.lower(input.value)
			if keyword == "h" and powerlessHue then
				return nil, "relative-powerless-hue-provider-required"
			end
			local value = channels[keyword]
			if value ~= nil then
				return number(value), nil
			end
			if keyword == "none" then
				return nil, "missing-color-component-provider-required"
			end
		end
		if input.children then
			local result = table.clone(input)
			local children: { Token } = {}
			for _, child in input.children do
				local nextToken, reason = replace(child)
				if not nextToken then
					return nil, reason
				end
				table.insert(children, nextToken)
			end
			result.children = children
			return result, nil
		end
		return input, nil
	end
	local children: { Token } = {}
	if profile then
		table.insert(children, { kind = "word", value = profile })
	end
	for index = start, count do
		local value, reason = replace(parts[index])
		if not value then
			return nil, reason, true
		end
		table.insert(children, value)
	end
	table.insert(children, { kind = "operator", value = "/" })
	local alpha, alphaFailure = replace(parts[count + 2] or number(base.alpha))
	if not alpha then
		return nil, alphaFailure, true
	end
	table.insert(children, alpha)
	local color, colorFailure = ColorFunctions.resolve({ kind = "function", value = name, children = children }, true)
	return color, colorFailure, true
end

return RelativeColors
