--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local FontVariantShorthand = require(script.Parent.FontVariantShorthand)
type Token = Types.ValueToken
local FontShorthand = {}
FontShorthand.targets = {
	"font-style",
	"font-weight",
	"font-width",
	"font-size",
	"line-height",
	"font-family",
	"font-feature-settings",
	"font-kerning",
	"font-language-override",
	"font-optical-sizing",
	"font-size-adjust",
	"font-variation-settings",
}
for _, name in FontVariantShorthand.targets do
	table.insert(FontShorthand.targets, name)
end
local sizes: { [string]: boolean } = {}
for name in ("xx-small x-small small medium large x-large xx-large xxx-large smaller larger math"):gmatch("%S+") do
	sizes[name] = true
end
local widths: { [string]: boolean } = {}
for name in
	("ultra-condensed extra-condensed condensed semi-condensed semi-expanded expanded extra-expanded ultra-expanded"):gmatch(
		"%S+"
	)
do
	widths[name] = true
end
local system: { [string]: boolean } = {}
for name in ("caption icon menu message-box small-caption status-bar"):gmatch("%S+") do
	system[name] = true
end
local mathFunctions = { calc = true, min = true, max = true, clamp = true }
local forbidden =
	{ initial = true, inherit = true, unset = true, revert = true, ["revert-layer"] = true, default = true }

local function numeric(token: Token): (string?, number?, string?)
	if token.kind == "dimension" and token.syntaxType == "length" then
		return "length", tonumber(token.value), nil
	end
	local value, failure = Measurements.resolve(
		{ token },
		{ percentageDimension = "length", allowLengthPercentage = true }
	)
	if value then
		return value.dimension, value.value, nil
	end
	local dimension, scalar, typeFailure = Measurements.classify(
		{ token },
		{ percentageDimension = "length", allowLengthPercentage = true }
	)
	return dimension, scalar, if dimension then nil else typeFailure or failure
end

function FontShorthand.resolve(target: string, parts: { Token }): ({ Token }?, string?)
	if not table.find(FontShorthand.targets, target) then
		return nil, "unknown-font-shorthand-target"
	end
	if #parts > 256 then
		return nil, "font-shorthand-provider-required"
	end
	if #parts == 1 and parts[1].kind == "word" and system[string.lower(parts[1].value)] then
		return nil, "font-system-provider-required"
	end
	local values: { [string]: { Token } } = {}
	local normals, explicit = 0, 0
	local sizeIndex: number? = nil
	local index = 1
	while index <= #parts do
		local token = parts[index]
		local name = string.lower(token.value)
		if token.kind == "percentage" and (tonumber(token.value) or -1) < 0 then
			return nil, "negative-font-size"
		end
		local property: string? = nil
		local tokens: { Token } = { token }
		if token.kind == "word" and sizes[name] then
			sizeIndex = index
			break
		elseif token.kind == "word" and name == "normal" then
			normals += 1
			index += 1
			continue
		elseif token.kind == "word" and (name == "italic" or name == "oblique") then
			property = "font-style"
			local after = parts[index + 1]
			if name == "oblique" and after and (after.kind == "dimension" or after.kind == "function") then
				local kind, angle = numeric(after)
				if kind == "angle" then
					if not angle then
						return nil, "font-shorthand-computation-pending:oblique-angle-context-required"
					end
					if angle < -90 or angle > 90 then
						return nil, "invalid-font-oblique-angle"
					end
					table.insert(tokens, after)
					index += 1
				end
			end
		elseif token.kind == "word" and name == "small-caps" then
			property = "font-variant-caps"
		elseif token.kind == "word" and widths[name] then
			property = "font-width"
		elseif token.kind == "word" and (name == "bold" or name == "bolder" or name == "lighter") then
			property = "font-weight"
		elseif
			token.kind == "number"
			or token.kind == "percentage"
			or token.kind == "dimension"
			or (token.kind == "function" and mathFunctions[name])
		then
			local kind, n, failure = numeric(token)
			if not kind then
				return nil, "font-shorthand-computation-pending:" .. (failure or "unknown")
			end
			-- Math functions retain their typed numeric result until typography
			-- applies the property's computed-value range. A bare zero instead
			-- occupies the unitless-zero font-size position.
			if kind == "number" and (token.kind == "function" or (n and n >= 1 and n <= 1000)) then
				property = "font-weight"
			elseif kind == "length" or (kind == "number" and n == 0) then
				if token.kind ~= "function" and (not n or n < 0 or n == math.huge) then
					return nil, "invalid-font-size"
				end
				sizeIndex = index
				break
			else
				return nil, "invalid-font-prefix-number"
			end
		elseif token.kind == "function" or token.kind == "raw" or token.value:find("\\") then
			return nil, "font-shorthand-provider-required"
		else
			return nil, "invalid-font-shorthand-prefix"
		end
		if values[property :: string] then
			return nil, "duplicate-font-shorthand-component"
		end
		values[property :: string] = tokens
		explicit += 1
		index += 1
	end
	if not sizeIndex or normals + explicit > 4 then
		return nil, "font-size-or-prefix-required"
	end
	values["font-size"] = { parts[sizeIndex] }
	index = sizeIndex + 1
	if parts[index] and parts[index].kind == "operator" and parts[index].value == "/" then
		index += 1
		local token = parts[index]
		if not token then
			return nil, "missing-font-line-height"
		end
		if token.kind == "percentage" and (tonumber(token.value) or -1) < 0 then
			return nil, "negative-font-line-height"
		end
		if not (token.kind == "word" and string.lower(token.value) == "normal") then
			if token.kind == "function" and mathFunctions[string.lower(token.value)] then
				local kind, _, failure = numeric(token)
				if not kind then
					return nil, "font-shorthand-computation-pending:" .. (failure or "unknown")
				end
				if kind ~= "length" and kind ~= "number" then
					return nil, "invalid-font-line-height-type"
				end
			elseif token.kind == "dimension" or token.kind == "number" or token.kind == "percentage" then
				local kind, n, failure = numeric(token)
				if not kind then
					return nil, "font-shorthand-computation-pending:" .. (failure or "unknown")
				end
				if (kind ~= "length" and kind ~= "number") or not n or n < 0 or n == math.huge then
					return nil, "invalid-font-line-height"
				end
			elseif token.kind == "function" or token.kind == "raw" then
				return nil, "font-shorthand-provider-required"
			else
				return nil, "invalid-font-line-height"
			end
		end
		values["line-height"] = { token }
		index += 1
	end
	local family: { Token } = {}
	local count, quoted = 0, false
	for cursor = index, #parts do
		local token = parts[cursor]
		if token.kind == "div" and token.value == "," then
			if count == 0 then
				return nil, "empty-font-family"
			end
			count, quoted = 0, false
		elseif token.kind == "word" then
			if quoted or forbidden[string.lower(token.value)] then
				return nil, "invalid-font-family"
			end
			if token.value:find("\\") then
				return nil, "font-shorthand-provider-required"
			end
			count += 1
		elseif token.kind == "string" then
			if count > 0 then
				return nil, "invalid-font-family"
			end
			count, quoted = 1, true
		elseif token.kind == "function" or token.kind == "raw" then
			return nil, "font-shorthand-provider-required"
		else
			return nil, "invalid-font-family"
		end
		table.insert(family, token)
	end
	if count == 0 then
		return nil, "font-family-required"
	end
	values["font-family"] = family
	return values[target] or { { kind = "word", value = "initial" } }, nil
end

return FontShorthand
