--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local BoxModel = require(script.Parent.BoxModel)

export type Ratio = { value: number, box: string }
local AspectRatio = {}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

function AspectRatio.resolve(style: Types.ComputedStyle, metrics: BoxModel.Metrics): (Ratio?, string?)
	if style.unresolved["aspect-ratio"] then
		return nil, style.unresolved["aspect-ratio"]
	end
	local tokens: { Types.ValueToken } = {}
	for _, token in style.properties["aspect-ratio"] or {} do
		if token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(tokens, token)
		end
	end
	if #tokens == 0 then
		return nil, nil
	end
	local auto = false
	for index = #tokens, 1, -1 do
		local token = tokens[index]
		if token.kind == "word" and string.lower(token.value) == "auto" then
			if auto or index ~= 1 and index ~= #tokens then
				return nil, "invalid-aspect-ratio-auto"
			end
			auto = true
			table.remove(tokens, index)
		end
	end
	if #tokens == 0 then
		return nil, nil
	end
	if #tokens ~= 1 and not (#tokens == 3 and tokens[2].kind == "operator" and tokens[2].value == "/") then
		return nil, "invalid-aspect-ratio-structure"
	end
	local function component(token: Types.ValueToken): (number?, string?)
		local value, failure = Measurements.resolve({ token }, { strictPercentageTypes = true })
		if not value or value.dimension ~= "number" then
			return nil, failure or "aspect-ratio-number-required"
		end
		if value.value < 0 and token.kind ~= "function" then
			return nil, "negative-aspect-ratio"
		end
		return math.max(0, value.value), nil
	end
	local numerator, firstFailure = component(tokens[1])
	local denominator: number? = 1
	local secondFailure: string? = nil
	if #tokens == 3 then
		denominator, secondFailure = component(tokens[3])
	end
	local n, d = numerator, denominator
	if n == nil or d == nil then
		return nil, firstFailure or secondFailure
	end
	if n == 0 or d == 0 then
		return nil, nil
	end
	local value = n / d
	if not finite(value) or value == 0 then
		return nil, "aspect-ratio-arithmetic-range-required"
	end
	local box = if auto then "content-box" else metrics.boxSizing
	if box ~= "content-box" and box ~= "border-box" then
		return nil, "invalid-aspect-ratio-box-sizing"
	end
	return { value = value, box = box }, nil
end

-- Input/output are content sizes; explicit ratios may operate on border sizes.
function AspectRatio.transfer(ratio: Ratio, size: number, from: string, metrics: BoxModel.Metrics): (number?, string?)
	if not finite(ratio.value) or ratio.value <= 0 or (ratio.box ~= "border-box" and ratio.box ~= "content-box") then
		return nil, "invalid-preferred-aspect-ratio"
	end
	if
		not finite(metrics.horizontalInset)
		or not finite(metrics.verticalInset)
		or metrics.horizontalInset < 0
		or metrics.verticalInset < 0
	then
		return nil, "invalid-aspect-ratio-insets"
	end
	if not finite(size) or size < 0 then
		return nil, "invalid-aspect-ratio-source-size"
	end
	local border = ratio.box == "border-box"
	local value: number
	if from == "width" then
		value = (size + (if border then metrics.horizontalInset else 0)) / ratio.value
			- (if border then metrics.verticalInset else 0)
	elseif from == "height" then
		value = (size + (if border then metrics.verticalInset else 0)) * ratio.value
			- (if border then metrics.horizontalInset else 0)
	else
		return nil, "invalid-aspect-ratio-source-axis"
	end
	if not finite(value) then
		return nil, "aspect-ratio-arithmetic-overflow"
	end
	return math.max(0, value), nil
end

-- Flex bases use an outer size before flooring the destination content size.
function AspectRatio.transferOuter(
	ratio: Ratio,
	outer: number,
	from: string,
	metrics: BoxModel.Metrics,
	floorContent: boolean?
): (number?, string?)
	local sourceInset = if from == "width" then metrics.horizontalInset else metrics.verticalInset
	local destinationInset = if from == "width" then metrics.verticalInset else metrics.horizontalInset
	local content, failure = AspectRatio.transfer(ratio, math.max(0, outer - sourceInset), from, metrics)
	if content == nil then
		return nil, failure
	end
	local result = if ratio.box == "border-box"
		then (if from == "width" then outer / ratio.value else outer * ratio.value)
		else content + destinationInset
	if not finite(outer) or outer < 0 or not finite(result) then
		return nil, "invalid-outer-ratio-transfer"
	end
	return if floorContent == false then result else math.max(destinationInset, result), nil
end

-- Transfer opposite constraints only into an automatic destination. Explicit
-- preferred/min/max sizes cap/floor transferred constraints independently.
function AspectRatio.constraints(
	ratio: Ratio,
	minimum: number?,
	maximum: number?,
	preferred: number?,
	ownMinimum: number?,
	ownMaximum: number?,
	from: string,
	metrics: BoxModel.Metrics
): (number?, number?, string?)
	local low, high: number? = nil, nil
	if minimum ~= nil then
		local failure: string?
		low, failure = AspectRatio.transfer(ratio, minimum, from, metrics)
		if low == nil then
			return nil, nil, failure
		end
		low = math.min(low, preferred or math.huge, ownMaximum or math.huge)
	end
	if maximum ~= nil then
		local failure: string?
		high, failure = AspectRatio.transfer(ratio, maximum, from, metrics)
		if high == nil then
			return nil, nil, failure
		end
		high = math.max(high, preferred or 0, ownMinimum or 0, low or 0)
	end
	return low, high, nil
end

return AspectRatio
