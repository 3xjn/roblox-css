--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local BoxModel = require(script.Parent.BoxModel)

local SizingValue = {}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function word(tokens: { Types.ValueToken }?): string?
	return if tokens and #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

-- All dimensions are normalized to the content box. Nil represents auto or
-- an unbounded maximum; the property name determines which is applicable.
function SizingValue.resolve(
	style: Types.ComputedStyle,
	property: string,
	metrics: BoxModel.Metrics,
	lengths: Measurements.Context,
	basis: number?,
	inset: number
): (number?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local minimum, maximum = property:sub(1, 4) == "min-", property:sub(1, 4) == "max-"
	local tokens = style.properties[property]
	local name = if tokens then word(tokens) else (if maximum then "none" else "auto")
	if name == "auto" and not maximum then
		return if minimum then 0 else nil, nil
	end
	if name == "none" and maximum then
		return nil, nil
	end
	if name or not tokens then
		return nil, `intrinsic-block-size-provider-required:{property}`
	end
	local context = table.clone(lengths)
	context.allowRatio = nil
	context.percentageDimension, context.percentageBasis = "length", basis
	local value, failure = Measurements.resolve(tokens, context)
	-- Inspect through the shared resolver before applying the percentage rule:
	-- an unknown function containing a percentage must remain unsupported.
	if not value and failure ~= "percentage-basis-required" then
		return nil, `{property}:{failure or "invalid"}`
	end
	-- CSS 2.2 sections 10.5/10.7: indefinite normal-flow block percentages
	-- behave as auto, zero minimum, or no maximum, including calc percentages.
	if basis == nil and Measurements.hasPercentage(tokens) then
		return if minimum then 0 else nil, nil
	end
	if not value or value.dimension ~= "length" and not (value.dimension == "number" and value.value == 0) then
		return nil, `{property}:{failure or "length-required"}`
	end
	local scalar = Measurements.toScalar(value, context)
	if scalar == nil or not finite(scalar) then
		return nil, `invalid-block-dimension:{property}`
	end
	if scalar < 0 and not (#tokens == 1 and tokens[1].kind == "function") then
		return nil, `negative-block-dimension:{property}`
	end
	return math.max(0, scalar - (if metrics.boxSizing == "border-box" then inset else 0)), nil
end

return SizingValue
