--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local Selectors = require(script.Parent.Selectors)
local Colors = require(script.Parent.Colors)

export type Environment = {
	viewportWidth: number?,
	viewportHeight: number?,
	initialFontSize: number?,
	mediaType: string?,
	-- Explicit capabilities/preferences such as pointer, hover and reduced motion.
	features: { [string]: string | number | boolean }?,
}

export type SupportsDeclaration = (string, { Types.ValueToken }, Types.Node) -> boolean?

local Conditions = {}

local function compare(a: number, operator: string, b: number): boolean?
	if operator == "=" then
		return a == b
	end
	if operator == "<" then
		return a < b
	end
	if operator == "<=" then
		return a <= b
	end
	if operator == ">" then
		return a > b
	end
	if operator == ">=" then
		return a >= b
	end
	return nil
end

local function dimension(name: string): string
	if name == "width" or name == "height" or name == "device-width" or name == "device-height" then
		return "length"
	end
	if name == "resolution" then
		return "resolution"
	end
	return "number"
end

local function featureValue(name: string, environment: Environment): (string | number | boolean)?
	if name == "width" then
		return environment.viewportWidth
	end
	if name == "height" then
		return environment.viewportHeight
	end
	if name == "aspect-ratio" then
		local width, height = environment.viewportWidth, environment.viewportHeight
		if width ~= nil and height ~= nil and height > 0 then
			return width / height
		end
		return nil
	end
	if name == "orientation" then
		local width, height = environment.viewportWidth, environment.viewportHeight
		if width ~= nil and height ~= nil then
			return if width > height then "landscape" else "portrait"
		end
		return nil
	end
	return if environment.features then environment.features[name] else nil
end

local function context(environment: Environment): Measurements.Context
	return {
		rootFontSize = environment.initialFontSize or 16,
		fontSize = environment.initialFontSize or 16,
		viewportWidth = environment.viewportWidth,
		viewportHeight = environment.viewportHeight,
		allowRatio = true,
	}
end

local function queryFeature(expression: Types.ConditionExpression, environment: Environment): boolean?
	local name = expression.name or ""
	local operator = "="
	if name:sub(1, 4) == "min-" then
		name = name:sub(5)
		operator = ">="
	elseif name:sub(1, 4) == "max-" then
		name = name:sub(5)
		operator = "<="
	end
	local actual = featureValue(name, environment)
	if actual == nil then
		return nil
	end
	local tokens = expression.tokens
	if not tokens then
		return actual ~= false and actual ~= 0 and actual ~= "none" and actual ~= "no-preference"
	end
	if type(actual) == "string" then
		return operator == "="
			and #tokens == 1
			and tokens[1].kind == "word"
			and string.lower(actual) == string.lower(tokens[1].value)
	end
	if type(actual) ~= "number" then
		return nil
	end
	local value = Measurements.resolve(tokens, context(environment))
	if not value or value.dimension ~= dimension(name) or (value.percentage or 0) ~= 0 then
		return nil
	end
	return compare(actual, operator, value.value)
end

local function rangeValue(operand: Types.RangeOperand, environment: Environment): Measurements.Quantity?
	if operand.kind == "feature" then
		local name = operand.name or ""
		local value = featureValue(name, environment)
		return if type(value) == "number" then { dimension = dimension(name), value = value } else nil
	end
	local result = Measurements.resolve(operand.tokens or {}, context(environment))
	return result
end

local evaluate: (Types.ConditionExpression, Environment, SupportsDeclaration?, Types.Node) -> boolean?

evaluate = function(
	expression: Types.ConditionExpression,
	environment: Environment,
	supportsDeclaration: SupportsDeclaration?,
	node: Types.Node
): boolean?
	local kind = expression.kind
	if kind == "not" then
		if not expression.operand then
			return nil
		end
		local value = evaluate(expression.operand, environment, supportsDeclaration, node)
		return if value ~= nil then not value else nil
	elseif kind == "and" or kind == "or" then
		local unknown = false
		for _, operand in expression.operands or {} do
			local value = evaluate(operand, environment, supportsDeclaration, node)
			if kind == "and" and value == false then
				return false
			end
			if kind == "or" and value == true then
				return true
			end
			if value == nil then
				unknown = true
			end
		end
		if unknown then
			return nil
		end
		return kind == "and"
	elseif kind == "media-type" then
		return expression.name == "all" or expression.name == (environment.mediaType or "screen")
	elseif kind == "feature" then
		return queryFeature(expression, environment)
	elseif kind == "range" then
		local operands = expression.rangeOperands or {}
		local comparisons = expression.comparisons or {}
		if #operands ~= #comparisons + 1 or #comparisons == 0 then
			return nil
		end
		for index, operator in comparisons do
			local left = rangeValue(operands[index], environment)
			local right = rangeValue(operands[index + 1], environment)
			if not left or not right or left.dimension ~= right.dimension then
				return nil
			end
			local matched = compare(left.value, operator, right.value)
			if matched ~= true then
				return matched
			end
		end
		return true
	elseif kind == "declaration" then
		local property = expression.property or ""
		local tokens = expression.tokens or {}
		local supplied = if supportsDeclaration then supportsDeclaration(property, tokens, node) else nil
		if supplied ~= nil then
			return supplied
		end
		-- Answer concrete color syntax through the same evaluator used by paint.
		if property == "color" then
			local color = Colors.resolve(tokens, { currentColor = { r = 0, g = 0, b = 0, alpha = 1 } })
			if color then
				return true
			end
		end
		-- A declaration the target cannot implement is an unsupported feature,
		-- not an indeterminate media query. This also permits CSS `not` to
		-- select the author's fallback as specified by feature queries.
		return false
	elseif kind == "selector" then
		-- selector() accepts one complex selector, not a selector list.
		if not expression.selectors or #expression.selectors ~= 1 then
			return false
		end
		for _, selector in expression.selectors or {} do
			local tokens, target, failure = Selectors.splitTarget(selector.tokens)
			if not tokens or target == "unavailable" or failure or Selectors.validate(tokens) ~= nil then
				return false
			end
		end
		return true
	elseif kind == "general-enclosed" then
		-- CSS supports uses false for forward-compatible unknown features.
		-- Missing renderer capabilities and unknown media features remain nil;
		-- their absence must not accidentally enable a negated fallback.
		return if expression.queryKind == "supports" then false else nil
	end
	return nil
end

function Conditions.match(
	condition: Types.Condition,
	environment: Environment,
	supportsDeclaration: SupportsDeclaration?,
	node: Types.Node
): boolean?
	if condition.name ~= "media" and condition.name ~= "supports" then
		return nil
	end
	if not condition.expression then
		return nil
	end
	return evaluate(condition.expression, environment, supportsDeclaration, node)
end

return Conditions
