--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)

local PositionValues = {}

local function word(tokens: { Types.ValueToken }?): string?
	return if tokens and #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

function PositionValues.inset(
	style: Types.ComputedStyle,
	property: string,
	basis: number?,
	units: Measurements.Context
): (number?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local tokens = style.properties[property]
	if not tokens or word(tokens) == "auto" then
		return nil, nil
	end
	local lengths = table.clone(units)
	lengths.allowRatio = nil
	lengths.percentageDimension = "length"
	lengths.percentageBasis = basis
	local value, failure = Measurements.resolve(tokens, lengths)
	if not value then
		return nil, `{property}:{failure or "invalid"}`
	end
	if value.dimension == "number" and value.value == 0 then
		return 0, nil
	end
	if value.dimension ~= "length" then
		return nil, `position-inset-length-percentage-required:{property}`
	end
	local result = Measurements.toScalar(value, lengths)
	if result == nil then
		return nil, `position-inset-percentage-basis-required:{property}`
	end
	if result ~= result or math.abs(result) == math.huge then
		return nil, `position-inset-arithmetic-range-required:{property}`
	end
	return result, nil
end

return PositionValues
