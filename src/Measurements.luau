--!strict

local Types = require(script.Parent.Types)
type Token = Types.ValueToken

export type MathRange = { read minimum: number?, read maximum: number? }

export type Context = {
	rootFontSize: number?,
	fontSize: number?,
	lineHeight: number?,
	rootLineHeight: number?,
	viewportWidth: number?,
	viewportHeight: number?,
	percentageBasis: number?,
	percentageDimension: string?,
	allowRatio: boolean?,
	-- Registered numeric grammars only combine lengths/percentages when their
	-- syntax supplies the corresponding percentage hint.
	strictPercentageTypes: boolean?,
	allowLengthPercentage: boolean?,
	-- Measured font metrics and additional viewport/container units, in CSS pixels.
	units: { [string]: number }?,
	-- The consuming property supplies supported calculation bounds. Omitted
	-- endpoints use the finite binary64 range; literals retain syntax checks.
	mathRange: MathRange?,
}

export type Quantity = {
	dimension: string,
	value: number,
	-- Non-nil means a length-percentage type, including a zero coefficient.
	percentage: number?,
	-- Internal to type classification; never returned by value resolution.
	unresolved: boolean?,
}

type EvaluationContext = Context & { typeOnly: boolean? }

local Measurements = {}

local absolute: { [string]: number } =
	{ px = 1, ["in"] = 96, cm = 96 / 2.54, mm = 96 / 25.4, q = 96 / 101.6, pt = 96 / 72, pc = 16 }
local angles: { [string]: number } = { deg = 1, grad = 0.9, rad = 180 / math.pi, turn = 360 }
local times: { [string]: number } = { s = 1, ms = 0.001 }
local resolutions: { [string]: number } = { dppx = 1, x = 1, dpi = 1 / 96, dpcm = 2.54 / 96 }
local maximumFinite = 1.7976931348623157e308
local constants = { e = math.exp(1), pi = math.pi, infinity = math.huge, ["-infinity"] = -math.huge, nan = 0 / 0 }

local function quantity(dimension: string, value: number, percentage: number?, unresolved: boolean?): Quantity
	return { dimension = dimension, value = value, percentage = percentage, unresolved = unresolved }
end

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function literal(token: Token, context: EvaluationContext): (Quantity?, string?)
	local value = tonumber(token.value)
	if not value or not finite(value) then
		return nil, "invalid-numeric-value"
	end
	if value == 0 then
		value = 0
	end -- CSS literal -0 is unsigned zero.
	if token.kind == "number" then
		return quantity("number", value), nil
	end
	if token.kind == "percentage" then
		if context.percentageDimension == "length" then
			return quantity("length", 0, value / 100), nil
		end
		if context.percentageDimension == "number" then
			return quantity("number", value / 100), nil
		end
		return quantity("percentage", value / 100), nil
	end
	local unit = token.unit or ""
	if absolute[unit] then
		return quantity("length", value * absolute[unit]), nil
	end
	if angles[unit] then
		return quantity("angle", value * angles[unit]), nil
	end
	if times[unit] then
		return quantity("time", value * times[unit]), nil
	end
	if resolutions[unit] then
		return quantity("resolution", value * resolutions[unit]), nil
	end
	local factor: number? = nil
	if unit == "rem" then
		factor = context.rootFontSize
	elseif unit == "em" then
		factor = context.fontSize
	elseif unit == "lh" then
		factor = context.lineHeight
	elseif unit == "rlh" then
		factor = context.rootLineHeight
	elseif unit == "vw" and context.viewportWidth then
		factor = context.viewportWidth / 100
	elseif unit == "vh" and context.viewportHeight then
		factor = context.viewportHeight / 100
	elseif (unit == "vmin" or unit == "vmax") and context.viewportWidth and context.viewportHeight then
		factor = (
			if unit == "vmin"
				then math.min(context.viewportWidth, context.viewportHeight)
				else math.max(context.viewportWidth, context.viewportHeight)
		) / 100
	elseif context.units then
		factor = context.units[unit]
	end
	if factor ~= nil then
		if not finite(factor) then
			return nil, "nonfinite-expression"
		end
		return quantity("length", value * factor), nil
	end
	if context.typeOnly and token.syntaxType == "length" then
		return quantity("length", 0, nil, true), nil
	end
	return nil, `unresolved-unit:{unit}`
end

local function comparable(value: Quantity, context: Context): number?
	if value.unresolved then
		return nil
	end
	local percentage = value.percentage or 0
	if percentage == 0 then
		return value.value
	end
	return if context.percentageBasis ~= nil then value.value + percentage * context.percentageBasis else nil
end

local function promote(a: Quantity, b: Quantity, context: Context): (Quantity, Quantity)
	if
		context.strictPercentageTypes
		and context.percentageDimension ~= "length"
		and not context.allowLengthPercentage
	then
		return a, b
	end
	if a.dimension == "percentage" and b.dimension == "length" then
		a = quantity("length", 0, a.value, a.unresolved)
	elseif b.dimension == "percentage" and a.dimension == "length" then
		b = quantity("length", 0, b.value, b.unresolved)
	end
	return a, b
end

local function scale(value: Quantity, factor: number, context: EvaluationContext): (Quantity?, string?)
	if context.typeOnly and value.unresolved then
		return quantity(value.dimension, 0, if value.percentage ~= nil then 0 else nil, true), nil
	end
	if factor ~= factor then
		return quantity(value.dimension, 0 / 0, if value.percentage ~= nil then 0 else nil, value.unresolved), nil
	end
	local amount = value.value * factor
	local percentage = if value.percentage ~= nil then value.percentage * factor else nil
	if value.percentage ~= nil and (not finite(amount) or not finite(percentage or 0)) then
		-- Distributing a nonfinite factor over a linear length/percentage pair
		-- can invent 0*infinity. Bind the actual operand before that operation.
		if context.percentageBasis ~= nil and not finite(context.percentageBasis) then
			return nil, "invalid-percentage-basis"
		end
		local scalar = comparable(value, context)
		if scalar == nil then
			if context.typeOnly then
				return quantity(value.dimension, 0, 0, true), nil
			end
			return nil, "nonfinite-percentage-basis-required"
		end
		return quantity(value.dimension, scalar * factor, 0, value.unresolved), nil
	end
	return quantity(value.dimension, amount, percentage, value.unresolved), nil
end

local function binary(
	operator: string,
	left: Quantity,
	right: Quantity,
	context: EvaluationContext,
	insideMath: boolean?
): (Quantity?, string?)
	if operator == "+" or operator == "-" then
		left, right = promote(left, right, context)
		if left.dimension ~= right.dimension then
			return nil, "incompatible-dimensions"
		end
		local sign = if operator == "+" then 1 else -1
		return quantity(
			left.dimension,
			left.value + sign * right.value,
			if left.percentage ~= nil or right.percentage ~= nil
				then (left.percentage or 0) + sign * (right.percentage or 0)
				else nil,
			left.unresolved or right.unresolved
		),
			nil
	elseif operator == "*" then
		if left.dimension == "number" then
			local result, failure = scale(right, left.value, context)
			if not result then
				return nil, failure
			end
			result.unresolved = result.unresolved or left.unresolved
			return result, nil
		end
		if right.dimension == "number" then
			local result, failure = scale(left, right.value, context)
			if not result then
				return nil, failure
			end
			result.unresolved = result.unresolved or right.unresolved
			return result, nil
		end
		return nil, "compound-dimension-product-pending"
	elseif operator == "/" then
		if right.dimension == "number" then
			if right.unresolved then
				return quantity(left.dimension, 0, left.percentage, true), nil
			end
			if right.value == 0 and not insideMath then
				return nil, "division-by-zero"
			end
			return scale(left, 1 / right.value, context)
		end
		if left.dimension ~= right.dimension then
			return nil,
				if context.strictPercentageTypes
					then "compound-dimension-quotient-pending"
					else "incompatible-dimensions"
		end
		local a, b = comparable(left, context), comparable(right, context)
		if a == nil or b == nil then
			if context.typeOnly then
				return quantity("number", 0, nil, true), nil
			end
			return nil, "percentage-basis-required"
		end
		if b == 0 and not insideMath then
			return nil, "division-by-zero"
		end
		return quantity("number", a / b), nil
	end
	return nil, `unsupported-operator:{operator}`
end

local function choose(a: Quantity, b: Quantity, minimum: boolean, context: EvaluationContext): (Quantity?, string?)
	a, b = promote(a, b, context)
	if a.dimension ~= b.dimension then
		return nil, "incompatible-dimensions"
	end
	if context.typeOnly and (a.unresolved or b.unresolved) then
		return quantity(a.dimension, 0, if a.percentage ~= nil or b.percentage ~= nil then 0 else nil, true), nil
	end
	if
		a.value ~= a.value
		or b.value ~= b.value
		or (a.percentage ~= nil and a.percentage ~= a.percentage)
		or (b.percentage ~= nil and b.percentage ~= b.percentage)
	then
		return quantity(a.dimension, 0 / 0, if a.percentage ~= nil or b.percentage ~= nil then 0 else nil), nil
	end
	local av: number?, bv: number?
	if (a.percentage or 0) == (b.percentage or 0) then
		av, bv = a.value, b.value
	else
		av, bv = comparable(a, context), comparable(b, context)
	end
	if av == nil or bv == nil then
		if context.typeOnly then
			return quantity(a.dimension, 0, 0, true), nil
		end
		return nil, "percentage-basis-required"
	end
	local leftValue, rightValue = av :: number, bv :: number
	local chosen: Quantity
	if leftValue ~= leftValue then
		chosen = a
	elseif rightValue ~= rightValue then
		chosen = b
	elseif leftValue == 0 and rightValue == 0 then
		-- min prefers negative zero; max prefers positive zero.
		local negative = 1 / leftValue == -math.huge
		chosen = if negative == minimum then a else b
	else
		chosen = if (minimum and leftValue <= rightValue) or (not minimum and leftValue >= rightValue) then a else b
	end
	if chosen.dimension == "length" and chosen.percentage == nil and (a.percentage ~= nil or b.percentage ~= nil) then
		chosen = quantity("length", chosen.value, 0)
	end
	return chosen, nil
end

local evaluate: ({ Token }, EvaluationContext, boolean?) -> (Quantity?, string?)

local function call(token: Token, context: EvaluationContext): (Quantity?, string?)
	local name = string.lower(token.value)
	local children = token.children or {}
	if name == "" or name == "calc" then
		return evaluate(children, context, true)
	end
	if name ~= "min" and name ~= "max" and name ~= "clamp" then
		return nil, `unsupported-math-function:{name}`
	end
	local groups: { { Token } } = { {} }
	for _, child in children do
		if child.kind == "div" and child.value == "," then
			table.insert(groups, {} :: { Token })
		else
			table.insert(groups[#groups], child)
		end
	end
	if name == "clamp" and #groups ~= 3 then
		return nil, "invalid-clamp-arguments"
	end
	local values: { Quantity } = {}
	for _, group in groups do
		local value, failure = evaluate(group, context, true)
		if not value then
			return nil, failure
		end
		table.insert(values, value)
	end
	if name == "clamp" then
		local bounded, failure = choose(values[2], values[3], true, context)
		if not bounded then
			return nil, failure
		end
		return choose(values[1], bounded, false, context)
	end
	local result = values[1]
	for index = 2, #values do
		local value, failure = choose(result, values[index], name == "min", context)
		if not value then
			return nil, failure
		end
		result = value
	end
	return result, nil
end

local function atom(token: Token?, context: EvaluationContext, insideMath: boolean?): (Quantity?, string?)
	if not token then
		return nil, "missing-expression-operand"
	end
	if token.kind == "function" then
		return call(token, context)
	end
	if token.kind == "number" or token.kind == "dimension" or token.kind == "percentage" then
		return literal(token, context)
	end
	if token.kind == "word" and insideMath then
		local value = constants[string.lower(token.value)]
		if value ~= nil then
			return quantity("number", value), nil
		end
	end
	return nil, `unsupported-math-token:{token.kind}:{token.value}`
end

local function operand(token: Token): boolean
	return token.kind ~= "space" and token.kind ~= "comment" and token.kind ~= "operator"
end

evaluate = function(tokens: { Token }, context: EvaluationContext, insideMath: boolean?): (Quantity?, string?)
	-- The compiler already supplies canonical tokens. Single atoms and one
	-- binary operation need no temporary token list or parser closures. Keep
	-- the same left-to-right evaluation, operators and context-dependent checks.
	if #tokens == 1 and operand(tokens[1]) then
		return atom(tokens[1], context, insideMath)
	end
	if #tokens == 3 and operand(tokens[1]) and operand(tokens[3]) then
		local operator = tokens[2]
		local value = operator.value
		if operator.kind == "operator" and (value == "+" or value == "-" or value == "*" or value == "/") then
			local left, failure = atom(tokens[1], context, insideMath)
			if not left then
				return nil, failure
			end
			local right, rightFailure = atom(tokens[3], context, insideMath)
			if not right then
				return nil, rightFailure
			end
			return binary(value, left, right, context, insideMath)
		end
	end
	local significant: { Token } = {}
	for _, token in tokens do
		if token.kind ~= "space" and token.kind ~= "comment" then
			local normalized = token
			if token.kind == "operator" then
				-- Accept existing artifacts whose CSS-tree operators retain the
				-- surrounding CSS whitespace. Never mutate stylesheet tokens.
				normalized = table.clone(token)
				normalized.value = token.value:match("^%s*(.-)%s*$") or token.value
			end
			table.insert(significant, normalized)
		end
	end
	local index = 1
	local function nextAtom(): (Quantity?, string?)
		local token = significant[index]
		index += 1
		return atom(token, context, insideMath)
	end
	local function product(): (Quantity?, string?)
		local left, failure = nextAtom()
		if not left then
			return nil, failure
		end
		while
			significant[index]
			and significant[index].kind == "operator"
			and (significant[index].value == "*" or significant[index].value == "/")
		do
			local operator = significant[index].value
			index += 1
			local right, rightFailure = nextAtom()
			if not right then
				return nil, rightFailure
			end
			local result, operationFailure = binary(operator, left, right, context, insideMath)
			if not result then
				return nil, operationFailure
			end
			left = result
		end
		return left, nil
	end
	local result, failure = product()
	if not result then
		return nil, failure
	end
	while
		significant[index]
		and significant[index].kind == "operator"
		and (significant[index].value == "+" or significant[index].value == "-")
	do
		local operator = significant[index].value
		index += 1
		local right, rightFailure = product()
		if not right then
			return nil, rightFailure
		end
		local value, operationFailure = binary(operator, result, right, context, insideMath)
		if not value then
			return nil, operationFailure
		end
		result = value
	end
	if index <= #significant then
		return nil, "unexpected-expression-token"
	end
	return result, nil
end

local function finish(value: Quantity?, failure: string?, mathFunction: boolean, context: Context): (Quantity?, string?)
	if not value then
		return nil, failure
	end
	if not mathFunction then
		if not finite(value.value) or not finite(value.percentage or 0) then
			return nil, "nonfinite-expression"
		end
		return value, nil
	end
	local range = context.mathRange
	local minimum = if range and range.minimum ~= nil then range.minimum else -maximumFinite
	local maximum = if range and range.maximum ~= nil then range.maximum else maximumFinite
	if range and (not finite(minimum) or not finite(maximum) or minimum > maximum) then
		return nil, "invalid-math-range"
	end
	local amount, percentage = value.value, value.percentage
	if amount ~= amount or (percentage ~= nil and percentage ~= percentage) then
		amount, percentage = 0, if percentage ~= nil then 0 else nil
	elseif percentage ~= nil and percentage ~= 0 and (range ~= nil or not finite(amount) or not finite(percentage)) then
		if context.percentageBasis ~= nil and not finite(context.percentageBasis) then
			return nil, "invalid-percentage-basis"
		end
		local scalar = comparable(value, context)
		if scalar == nil then
			return nil, "math-range-percentage-basis-required"
		end
		amount, percentage = scalar, 0
	end
	if amount ~= amount then
		amount = 0
	end
	if not finite(amount) and not range then
		return nil, "math-range-required"
	end
	if range then
		amount = math.clamp(amount, minimum, maximum)
	end
	-- Signed zero and special values cannot escape the outer calculation.
	if amount == 0 then
		amount = 0
	end
	if percentage == 0 then
		percentage = 0
	end
	local signedZero = (value.value == 0 and 1 / value.value == -math.huge)
		or (value.percentage == 0 and 1 / (value.percentage :: number) == -math.huge)
	if amount == value.value and percentage == value.percentage and not signedZero then
		return value, nil
	end
	return quantity(value.dimension, amount, percentage, value.unresolved), nil
end

function Measurements.resolve(tokens: { Token }, context: Context): (Quantity?, string?)
	-- Keep classification mode private even if a caller supplies an extra field.
	local options = context :: EvaluationContext
	if options.typeOnly then
		options = table.clone(options)
		options.typeOnly = nil
	end
	-- A numeric leaf needs no expression parser or significant-token copies.
	-- Use the same unit/context conversion and final finite check as evaluate.
	if #tokens == 1 then
		local token = tokens[1]
		if token.kind == "number" or token.kind == "dimension" or token.kind == "percentage" then
			local value, failure = literal(token, options)
			if not value then
				return nil, failure
			end
			if not finite(value.value) or not finite(value.percentage or 0) then
				return nil, "nonfinite-expression"
			end
			return value, nil
		end
	end
	local significant = {}
	for _, token in tokens do
		if token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(significant, token)
		end
	end
	if #significant == 1 then
		local value, failure = evaluate(significant, options)
		return finish(value, failure, significant[1].kind == "function", options)
	end
	if
		context.allowRatio
		and #significant == 3
		and significant[1].kind == "number"
		and significant[2].kind == "operator"
		and significant[2].value == "/"
		and significant[3].kind == "number"
	then
		local value, failure = evaluate(significant, options)
		return finish(value, failure, false, options)
	end
	return nil, "expected-single-value-or-math-function"
end

-- Infer a bounded math value's type without inventing missing font/viewport
-- metrics. Known scalar results are retained; unresolved scalars are omitted.
-- The ordinary resolver never enables this mode or publishes its placeholders.
function Measurements.classify(tokens: { Token }, context: Context): (string?, number?, string?)
	local options = table.clone(context) :: EvaluationContext
	options.typeOnly = true
	local significant = {}
	for _, token in tokens do
		if token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(significant, token)
		end
	end
	if #significant ~= 1 then
		return nil, nil, "expected-single-value-or-math-function"
	end
	local value, failure = evaluate(significant, options)
	if not value then
		return nil, nil, failure
	end
	local scalar = comparable(value, context)
	if scalar and not finite(scalar) then
		scalar = if scalar ~= scalar then 0 else nil
	end
	if scalar == 0 then
		scalar = 0
	end
	return value.dimension, scalar, nil
end

function Measurements.hasPercentage(tokens: { Token }): boolean
	for _, token in tokens do
		if token.kind == "percentage" or token.children and Measurements.hasPercentage(token.children) then
			return true
		end
	end
	return false
end

Measurements.toScalar = comparable
return Measurements
