--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
type Token = Types.ValueToken

local GridLine = {}
export type Line = { kind: "auto" | "line" | "span", index: number?, name: string? }
local forbidden =
	{ initial = true, inherit = true, unset = true, revert = true, ["revert-layer"] = true, default = true }
local maximumInteger = 9007199254740991

-- CSS-wide handling belongs to Variables/cascade, before this value grammar.
-- Keep identifiers case-sensitive and use the compiler's escape metadata.
function GridLine.parse(tokens: { Token }, units: Measurements.Context?): (Line?, string?)
	local span, automatic = false, false
	local index: number? = nil
	local calculated = false
	local name: string? = nil
	local count = 0
	for _, token in tokens do
		if token.kind == "space" or token.kind == "comment" then
			continue
		end
		count += 1
		if token.kind == "word" then
			if token.value:find("\\", 1, true) and not token.identifier then
				return nil, "grid-line-identifier-metadata-required"
			end
			local identifier = token.identifier or token.value
			local lower = string.lower(identifier)
			if lower == "span" then
				if span then
					return nil, "duplicate-grid-span"
				end
				span = true
			elseif lower == "auto" then
				automatic = true
			elseif forbidden[lower] or name ~= nil then
				return nil, "invalid-grid-line-name"
			else
				name = identifier
			end
		elseif token.kind == "number" or token.kind == "function" then
			if index ~= nil then
				return nil, "duplicate-grid-line-integer"
			end
			if token.kind == "number" and not token.value:match("^[+-]?%d+$") then
				return nil, "grid-line-integer-required"
			end
			local value, failure = Measurements.resolve({ token }, units or {})
			if not value then
				if failure == "incompatible-dimensions" then
					return nil, "grid-line-integer-required"
				end
				return nil, `grid-line-number-computation-pending:{failure or "unknown"}`
			end
			if value.dimension ~= "number" or value.percentage ~= nil then
				return nil, "grid-line-integer-required"
			end
			local number = value.value
			if token.kind == "function" then
				local floor = math.floor(number)
				number = if number - floor >= 0.5 then floor + 1 else floor
				calculated = true
			end
			if number ~= number or math.abs(number) > maximumInteger then
				return nil, "grid-line-integer-range-provider-required"
			end
			if number % 1 ~= 0 then
				return nil, "grid-line-integer-required"
			end
			index = number
		elseif token.kind == "raw" then
			return nil, "grid-line-syntax-provider-required"
		else
			return nil, "invalid-grid-line-component"
		end
	end
	if automatic then
		return if count == 1 then { kind = "auto" } else nil,
			if count == 1 then nil else "invalid-grid-auto-combination"
	end
	if count == 0 or (span and index == nil and name == nil) then
		return nil, "incomplete-grid-line"
	end
	if span and calculated and index ~= nil then
		index = math.max(1, index)
	end
	if index == 0 or (span and index ~= nil and index < 0) then
		return nil, "invalid-grid-line-integer"
	end
	return { kind = if span then "span" else "line", index = index, name = name }, nil
end

function GridLine.pending(failure: string?): boolean
	return failure == "grid-line-identifier-metadata-required"
		or failure == "grid-line-integer-range-provider-required"
		or failure == "grid-line-syntax-provider-required"
		or (
			failure ~= nil
			and failure:sub(1, #"grid-line-number-computation-pending:") == "grid-line-number-computation-pending:"
		)
end

return GridLine
