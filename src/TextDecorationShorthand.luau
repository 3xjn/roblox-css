--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local Colors = require(script.Parent.Colors)
type Token = Types.ValueToken

local TextDecorationShorthand = {}
TextDecorationShorthand.targets = {
	"text-decoration-line",
	"text-decoration-style",
	"text-decoration-color",
	"text-decoration-thickness",
}
local lines = { underline = true, overline = true, ["line-through"] = true, blink = true }
local exclusive = { none = true, ["spelling-error"] = true, ["grammar-error"] = true }
local styles = { solid = true, double = true, dotted = true, dashed = true, wavy = true }
local mathFunctions = { calc = true, min = true, max = true, clamp = true }

local function zero(): Token
	return { kind = "dimension", value = "0", unit = "px" }
end

function TextDecorationShorthand.resolve(target: string, parts: { Token }): ({ Token }?, string?)
	if not table.find(TextDecorationShorthand.targets, target) then
		return nil, "unknown-text-decoration-shorthand-target"
	end
	if #parts == 0 then
		return nil, "empty-text-decoration-shorthand"
	end
	local values: { [string]: { Token } } = {}
	local lineTokens: { Token } = {}
	local seen: { [string]: boolean } = {}
	local hasExclusive = false
	local lastLine = 0
	for index, token in parts do
		local name = string.lower(token.value)
		local key: string? = nil
		local value: Token = token
		if token.kind == "word" and (lines[name] or exclusive[name]) then
			if #lineTokens > 0 and lastLine ~= index - 1 then
				return nil, "noncontiguous-text-decoration-line"
			end
			if seen[name] or hasExclusive or (exclusive[name] and #lineTokens > 0) then
				return nil, "invalid-text-decoration-line-combination"
			end
			seen[name] = true
			hasExclusive = exclusive[name] == true
			table.insert(lineTokens, token)
			lastLine = index
			continue
		elseif token.kind == "word" and styles[name] then
			key = "text-decoration-style"
		elseif token.kind == "word" and (name == "auto" or name == "from-font") then
			key = "text-decoration-thickness"
		elseif
			token.syntaxType == "color"
			or token.color
			or (token.kind == "word" and name == "currentcolor")
			or (token.kind == "function" and Colors.isColorFunction(name))
		then
			key = "text-decoration-color"
		elseif token.kind == "function" and mathFunctions[name] then
			local measured, failure = Measurements.resolve(
				{ token },
				{ percentageDimension = "length", allowLengthPercentage = true }
			)
			if not measured then
				return nil, "text-decoration-shorthand-computation-pending:" .. (failure or "unknown")
			end
			if measured.dimension ~= "length" and not (measured.dimension == "number" and measured.value == 0) then
				return nil, "invalid-text-decoration-thickness-type"
			end
			if measured.value < 0 and (measured.percentage or 0) == 0 then
				value = zero()
			end
			key = "text-decoration-thickness"
		elseif token.kind == "dimension" or token.kind == "percentage" or token.kind == "number" then
			local n = tonumber(token.value)
			if not n or n ~= n or math.abs(n) == math.huge or n < 0 then
				return nil, "invalid-text-decoration-thickness"
			end
			if token.kind == "number" and n ~= 0 then
				return nil, "nonzero-unitless-text-decoration-thickness"
			end
			if token.kind == "dimension" and token.syntaxType ~= "length" then
				-- Older/custom token producers may omit the optional lexer hint.
				local measured = Measurements.resolve({ token }, {})
				if not measured then
					return nil, "text-decoration-shorthand-provider-required"
				elseif measured.dimension ~= "length" then
					return nil, "invalid-text-decoration-thickness-type"
				end
			end
			key = "text-decoration-thickness"
		elseif token.kind == "function" or token.kind == "raw" or token.value:find("\\") then
			return nil, "text-decoration-shorthand-provider-required"
		else
			return nil, "invalid-text-decoration-shorthand-component"
		end
		if values[key :: string] then
			return nil, `duplicate-text-decoration-component:{key :: string}`
		end
		values[key :: string] = { value }
	end
	if #lineTokens > 0 then
		values["text-decoration-line"] = lineTokens
	end
	return values[target] or { { kind = "word", value = "initial" } }, nil
end

return TextDecorationShorthand
