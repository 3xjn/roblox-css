--!strict

local Types = require(script.Parent.Types)
local BoxModel = require(script.Parent.BoxModel)
local Measurements = require(script.Parent.Measurements)

export type Result = { x: number, y: number, establishesContext: boolean }
local TranslationTransform = {}

local defaults: { [string]: string } = {
	rotate = "none",
	scale = "none",
	perspective = "none",
	["transform-style"] = "flat",
	["offset-path"] = "none",
}
local transformProperties = { "translate", "transform", "transform-box" }

local function parts(tokens: { Types.ValueToken }?): { Types.ValueToken }
	local result = {}
	for _, token in tokens or {} do
		if token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(result, token)
		end
	end
	return result
end

local function word(tokens: { Types.ValueToken }?): string?
	if not tokens then return nil end
	local value: string? = nil
	for _, token in tokens do
		if token.kind ~= "space" and token.kind ~= "comment" then
			if value or token.kind ~= "word" then return nil end
			value = string.lower(token.value)
		end
	end
	return value
end

local function length(token: Types.ValueToken, basis: number?, units: Measurements.Context): (number?, string?)
	local context = table.clone(units)
	context.allowRatio = nil
	context.strictPercentageTypes = true
	context.allowLengthPercentage = basis ~= nil
	context.percentageDimension = if basis ~= nil then "length" else nil
	context.percentageBasis = basis
	local value, failure = Measurements.resolve({ token }, context)
	if not value then
		return nil, failure or "invalid-translation-length"
	end
	if value.dimension == "number" and value.value == 0 and token.kind == "number" then
		return 0, nil
	end
	if value.dimension ~= "length" then
		return nil, "translation-length-percentage-required"
	end
	local scalar = Measurements.toScalar(value, context)
	if scalar == nil or scalar ~= scalar or math.abs(scalar) == math.huge then
		return nil, "translation-arithmetic-range-required"
	end
	return scalar, nil
end

local function arguments(tokens: { Types.ValueToken }): ({ Types.ValueToken }?, string?)
	local result: { Types.ValueToken } = {}
	local expectValue = true
	for _, token in parts(tokens) do
		if expectValue then
			if token.kind == "div" then
				return nil, "invalid-translation-function-arguments"
			end
			table.insert(result, token)
		else
			if token.kind ~= "div" or token.value ~= "," then
				return nil, "comma-separated-transform-arguments-required"
			end
		end
		expectValue = not expectValue
	end
	if expectValue then
		return nil, "invalid-translation-function-arguments"
	end
	return result, nil
end

-- CSS layout boxes only. SVG reference geometry and general affine/3D
-- transforms need separate providers; none of them are approximated here.
function TranslationTransform.resolve(
	style: Types.ComputedStyle,
	geometry: BoxModel.Geometry,
	units: Measurements.Context
): (Result?, string?)
	for name, initial in defaults do
		if style.unresolved[name] then
			return nil, `{name}:{style.unresolved[name]}`
		end
		local tokens = style.properties[name]
		if tokens and word(tokens) ~= initial then
			return nil, `nontranslation-transform-provider-required:{name}`
		end
	end
	for _, name in transformProperties do
		if style.unresolved[name] then
			return nil, `{name}:{style.unresolved[name]}`
		end
	end
	local box = word(style.properties["transform-box"])
		or (if not style.properties["transform-box"] then "view-box" else nil)
	local width: number
	local height: number
	if box == "content-box" or box == "fill-box" then
		width, height = geometry.contentWidth, geometry.contentHeight
	elseif box == "border-box" or box == "stroke-box" or box == "view-box" then
		width, height = geometry.width, geometry.height
	else
		return nil, "transform-reference-box-provider-required"
	end
	if width < 0 or height < 0 or width ~= width or height ~= height or width == math.huge or height == math.huge then
		return nil, "invalid-transform-reference-geometry"
	end
	local result: Result = { x = 0, y = 0, establishesContext = false }
	-- Keep reference-box and unresolved-value validation above this path.
	-- An explicit zero translate still establishes a CSS transform context.
	if (not style.properties.translate or word(style.properties.translate) == "none")
		and (not style.properties.transform or word(style.properties.transform) == "none")
	then
		return result, nil
	end
	local function add(xToken: Types.ValueToken?, yToken: Types.ValueToken?, zToken: Types.ValueToken?): string?
		local x: number? = 0
		local y: number? = 0
		local z: number? = 0
		local failure: string? = nil
		if xToken then
			x, failure = length(xToken, width, units)
		end
		if x == nil then
			return failure
		end
		if yToken then
			y, failure = length(yToken, height, units)
		end
		if y == nil then
			return failure
		end
		if zToken then
			z, failure = length(zToken, nil, units)
		end
		if z == nil then
			return failure
		end
		if z ~= 0 then
			return "nonzero-z-transform-provider-required"
		end
		result.x += x
		result.y += y
		return nil
	end
	local individual = parts(style.properties.translate)
	if #individual > 0 and word(individual) ~= "none" then
		if #individual > 3 then
			return nil, "invalid-individual-translate"
		end
		local failure = add(individual[1], individual[2], individual[3])
		if failure then
			return nil, failure
		end
		result.establishesContext = true
	elseif style.properties.translate and #individual == 0 then
		return nil, "invalid-individual-translate"
	end
	local transforms = parts(style.properties.transform)
	if #transforms > 0 and word(transforms) ~= "none" then
		result.establishesContext = true
		for _, token in transforms do
			if token.kind ~= "function" then
				return nil, "transform-function-list-required"
			end
			local args, argumentFailure = arguments(token.children or {})
			if not args then
				return nil, argumentFailure
			end
			local name = string.lower(token.value)
			local failure: string? = nil
			if name == "translate" and (#args == 1 or #args == 2) then
				failure = add(args[1], args[2], nil)
			elseif name == "translatex" and #args == 1 then
				failure = add(args[1], nil, nil)
			elseif name == "translatey" and #args == 1 then
				failure = add(nil, args[1], nil)
			elseif name == "translate3d" and #args == 3 then
				failure = add(args[1], args[2], args[3])
			elseif name == "translatez" and #args == 1 then
				failure = add(nil, nil, args[1])
			elseif name == "matrix" and #args == 6 then
				local values: { number } = {}
				for _, argument in args do
					local value, reason = Measurements.resolve({ argument }, { strictPercentageTypes = true })
					if not value or value.dimension ~= "number" then
						return nil, reason or "transform-matrix-number-required"
					end
					table.insert(values, value.value)
				end
				if values[1] ~= 1 or values[2] ~= 0 or values[3] ~= 0 or values[4] ~= 1 then
					return nil, "nontranslation-matrix-provider-required"
				end
				result.x += values[5]
				result.y += values[6]
			else
				return nil, `transform-function-provider-required:{name}`
			end
			if failure then
				return nil, failure
			end
		end
	elseif style.properties.transform and #transforms == 0 then
		return nil, "invalid-transform-function-list"
	end
	if
		result.x ~= result.x
		or result.y ~= result.y
		or math.abs(result.x) == math.huge
		or math.abs(result.y) == math.huge
	then
		return nil, "translation-arithmetic-range-required"
	end
	return result, nil
end

return TranslationTransform
