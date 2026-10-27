--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local Colors = require(script.Parent.Colors)
type Token = Types.ValueToken
type Branch = { kind: "type" | "keyword", name: string, list: "single" | "space" | "comma" }

local RegisteredValues = {}
local numeric = {
	length = "length",
	["length-percentage"] = "length",
	number = "number",
	integer = "number",
	percentage = "percentage",
	angle = "angle",
	time = "time",
	resolution = "resolution",
}
local canonical = { length = "px", angle = "deg", time = "s", resolution = "dppx" }

local function serializedColor(color: Types.RgbaColor): ({ Token }?, string?)
	local children: { Token } = { { kind = "word", value = "srgb" } }
	for index, value in { color.r, color.g, color.b, color.alpha } do
		if value ~= value or math.abs(value) == math.huge then
			return nil, "registered-color-arithmetic-range-required"
		end
		table.insert(children, { kind = "space", value = " " })
		if index == 4 then
			table.insert(children, { kind = "operator", value = "/" })
			table.insert(children, { kind = "space", value = " " })
		end
		table.insert(children, { kind = "number", value = string.format("%.17g", if value == 0 then 0 else value) })
	end
	-- Absolute color(srgb ...) preserves extended channels. rgb() would clamp
	-- them if the computed token were serialized and parsed again.
	return { { kind = "function", value = "color", children = children, color = table.clone(color) } }, nil
end

local function serializedQuantity(quantity: Measurements.Quantity, percentageHint: boolean): { Token }
	local function scalar(kind: string, value: number, unit: string?): Token
		return { kind = kind, value = string.format("%.17g", if value == 0 then 0 else value), unit = unit }
	end
	if quantity.dimension == "number" then
		return { scalar("number", quantity.value, nil) }
	elseif quantity.dimension == "percentage" then
		return { scalar("percentage", quantity.value * 100, nil) }
	elseif quantity.dimension == "length" and percentageHint then
		-- Retain the percentage type even when its coefficient cancels to zero.
		return {
			{
				kind = "function",
				value = "calc",
				children = {
					scalar("dimension", quantity.value, "px"),
					{ kind = "space", value = " " },
					{ kind = "operator", value = "+" },
					{ kind = "space", value = " " },
					scalar("percentage", (quantity.percentage or 0) * 100, nil),
				},
			},
		}
	end
	return { scalar("dimension", quantity.value, canonical[quantity.dimension]) }
end

-- A nil value with a reason is unsupported computation, not invalid CSS.
-- A nil value without a reason is a proven grammar mismatch.
local function single(token: Token, branch: Branch): ({ Token }?, string?)
	if branch.kind == "keyword" then
		if token.kind == "word" and token.value == branch.name then
			return { token }, nil
		end
		if token.kind == "raw" or token.value:find("\\", 1, true) then
			return nil, "registered-identifier-decoding-pending"
		end
		return nil, nil
	end
	local dimension = numeric[branch.name]
	if dimension then
		local expression = token.kind == "function"
		local name = string.lower(token.value)
		if
			token.kind == "raw"
			or expression and name ~= "calc" and name ~= "min" and name ~= "max" and name ~= "clamp"
		then
			return nil, "registered-numeric-expression-pending"
		end
		if not expression and token.kind ~= "number" and token.kind ~= "percentage" and token.kind ~= "dimension" then
			return nil, nil
		end
		local quantity, failure = Measurements.resolve({ token }, {
			strictPercentageTypes = true,
			allowLengthPercentage = branch.name == "length-percentage",
		})
		if not quantity then
			if failure == "incompatible-dimensions" then
				return nil, nil
			end
			return nil, failure
		end
		local zeroLength = token.kind == "number" and quantity.value == 0
		if branch.name == "length-percentage" and quantity.dimension == "percentage" then
			return if expression then serializedQuantity(quantity, false) else { token }, nil
		elseif quantity.dimension ~= dimension and not (dimension == "length" and zeroLength) then
			return nil, nil
		elseif branch.name == "integer" and not expression and not token.value:match("^[%+%-]?%d+$") then
			return nil, nil
		end
		if expression then
			if branch.name == "integer" then
				local floor = math.floor(quantity.value)
				local rounded = if quantity.value - floor >= 0.5 then floor + 1 else floor
				return { { kind = "number", value = string.format("%.0f", if rounded == 0 then 0 else rounded) } }, nil
			end
			return serializedQuantity(quantity, quantity.percentage ~= nil), nil
		elseif dimension == "percentage" or dimension == "number" or zeroLength then
			return { token }, nil
		end
		return serializedQuantity(quantity, false), nil
	elseif branch.name == "string" then
		return if token.kind == "string" then { token } else nil,
			if token.kind == "raw" or token.kind == "function" then "registered-string-computation-pending" else nil
	elseif branch.name == "color" then
		if token.color then
			return serializedColor(token.color)
		end
		if
			token.kind == "dimension"
			or token.kind == "number"
			or token.kind == "percentage"
			or token.kind == "string"
		then
			return nil, nil
		end
		if token.kind == "function" then
			local value, failure = Colors.resolve({ token }, {})
			if value then
				return serializedColor(value)
			end
			return nil, failure or "registered-color-computation-pending"
		end
		return nil, "registered-color-computation-pending"
	elseif branch.name == "custom-ident" then
		if token.kind ~= "word" then
			return nil, if token.kind == "raw" then "registered-identifier-decoding-pending" else nil
		end
		if not token.value:match("^%-?[_a-zA-Z][_%w%-]*$") then
			return nil, "registered-identifier-decoding-pending"
		end
		local lower = string.lower(token.value)
		if
			lower == "default"
			or lower == "initial"
			or lower == "inherit"
			or lower == "unset"
			or lower == "revert"
			or lower == "revert-layer"
		then
			return nil, nil
		end
		return { token }, nil
	end
	return nil, `registered-type-computation-pending:{branch.name}`
end

local function alternative(tokens: { Token }, branch: Branch): ({ Token }?, string?)
	local output: { Token } = {}
	local count = 0
	local expectValue = true
	for _, token in tokens do
		if token.kind == "space" or token.kind == "comment" then
			continue
		elseif token.kind == "div" and token.value == "," then
			if branch.list ~= "comma" or expectValue then
				return nil, nil
			end
			expectValue = true
			table.insert(output, token)
		else
			if count > 0 and (branch.list == "single" or branch.list == "comma" and not expectValue) then
				return nil, nil
			end
			local value, failure = single(token, branch)
			if not value then
				return nil, failure
			end
			if branch.list == "space" and count > 0 then
				table.insert(output, { kind = "space", value = " " })
			end
			for _, part in value do
				table.insert(output, part)
			end
			count += 1
			expectValue = false
		end
	end
	return if count > 0 and not expectValue then output else nil, nil
end

function RegisteredValues.compute(tokens: { Token }, registration: Types.Registration): ({ Token }?, string?)
	local syntax = registration.syntaxDefinition
	if not syntax then
		return nil, "registered-syntax-definition-required"
	elseif syntax.universal then
		return tokens, nil
	end
	for _, branch in syntax.branches do
		local value, failure = alternative(tokens, branch)
		if value or failure then
			return value, failure
		end
	end
	return nil, nil
end

return RegisteredValues
