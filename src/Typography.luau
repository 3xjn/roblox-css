--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
type Token = Types.ValueToken

export type Metrics = {
	[string]: number?,
	ex: number?,
	ch: number?,
	cap: number?,
	ic: number?,
	normalLineHeight: number?,
	-- Authoritative font ascent/descent in em units, used by inline struts.
	ascent: number?,
	descent: number?,
}
export type Context = {
	initialFontSize: number,
	rootFontSize: number?,
	rootLineHeight: number?,
	viewportWidth: number?,
	viewportHeight: number?,
	parentMetrics: Metrics?,
	fontSizeKeywords: { [string]: number }?,
}
export type MetricsProvider = (Types.ComputedStyle) -> Metrics?

local Typography = {}
local sizeKeywords: { [string]: boolean } = {
	["xx-small"] = true,
	["x-small"] = true,
	small = true,
	medium = true,
	large = true,
	["x-large"] = true,
	["xx-large"] = true,
	["xxx-large"] = true,
	smaller = true,
	larger = true,
	math = true,
}

local function word(tokens: { Token }?): string?
	return if tokens and #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

local function numberToken(value: number): { Token }
	return { { kind = "number", value = tostring(value) } }
end

local function pixels(value: number): { Token }
	return { { kind = "dimension", value = tostring(value), unit = "px" } }
end

function Typography.fontSize(style: Types.ComputedStyle): number?
	local tokens = style.properties["font-size"]
	if style.unresolved["font-size"] or not tokens or #tokens ~= 1 then
		return nil
	end
	local token = tokens[1]
	return if token.kind == "dimension" and token.unit == "px" then tonumber(token.value) else nil
end

local function weight(style: Types.ComputedStyle?): number?
	if not style then
		return 400
	end
	if style.unresolved["font-weight"] then
		return nil
	end
	local tokens = style.properties["font-weight"]
	if not tokens then
		return 400
	end
	local name = word(tokens)
	if name == "normal" then
		return 400
	end
	if name == "bold" then
		return 700
	end
	local measured = Measurements.resolve(tokens, {})
	return if measured and measured.dimension == "number" then measured.value else nil
end

function Typography.lineHeight(style: Types.ComputedStyle, metrics: Metrics?): number?
	if style.unresolved["line-height"] then
		return nil
	end
	local tokens = style.properties["line-height"]
	local size = Typography.fontSize(style)
	if not size then
		return nil
	end
	if not tokens or word(tokens) == "normal" then
		return if metrics and metrics.normalLineHeight then size * metrics.normalLineHeight else nil
	end
	if #tokens ~= 1 then
		return nil
	end
	if tokens[1].kind == "number" then
		return size * (tonumber(tokens[1].value) or 0)
	end
	return if tokens[1].kind == "dimension" and tokens[1].unit == "px" then tonumber(tokens[1].value) else nil
end

local function lengths(context: Context, size: number?, lineHeight: number?, metrics: Metrics?): Measurements.Context
	local units: { [string]: number } = {}
	if metrics and size then
		for _, unit in { "ex", "ch", "cap", "ic" } do
			local ratio = metrics[unit]
			if ratio ~= nil then
				units[unit] = size * ratio
			end
		end
	end
	return {
		fontSize = size,
		rootFontSize = context.rootFontSize,
		lineHeight = lineHeight,
		rootLineHeight = context.rootLineHeight,
		viewportWidth = context.viewportWidth,
		viewportHeight = context.viewportHeight,
		units = units,
	}
end

function Typography.resolve(
	style: Types.ComputedStyle,
	parent: Types.ComputedStyle?,
	context: Context,
	metricsProvider: MetricsProvider?,
	diagnose: Types.Diagnose
): (Types.ComputedStyle, Metrics?)
	local result: Types.ComputedStyle = {
		properties = table.clone(style.properties),
		variables = style.variables,
		unresolvedVariables = style.unresolvedVariables,
		priorities = style.priorities,
		unresolved = table.clone(style.unresolved),
	}
	local properties = result.properties
	local function fail(property: string, reason: string)
		result.unresolved[property] = reason
		diagnose("unresolved-computed-value", `{property}: {reason}`, nil)
	end
	local function invalid(property: string, initial: { Token })
		properties[property] = if parent then (parent.properties[property] or initial) else initial
		result.unresolved[property] = if parent then parent.unresolved[property] else nil
		diagnose("invalid-computed-value", property, nil)
	end
	if not result.unresolved["font-weight"] then
		local name = word(properties["font-weight"])
		local value = weight(result)
		local tokens = properties["font-weight"]
		if value and tokens and #tokens == 1 and tokens[1].kind == "function" then
			value = math.clamp(value, 1, 1000)
		end
		if name == "bolder" or name == "lighter" then
			local inherited = weight(parent)
			if inherited then
				if name == "bolder" then
					value = if inherited < 350
						then 400
						elseif inherited < 550 then 700
						elseif inherited < 900 then 900
						else inherited
				else
					value = if inherited < 100
						then inherited
						elseif inherited < 550 then 100
						elseif inherited < 750 then 400
						else 700
				end
			end
		end
		if value and value >= 1 and value <= 1000 then
			properties["font-weight"] = numberToken(value)
		else
			if name and name ~= "bolder" and name ~= "lighter" then
				invalid("font-weight", numberToken(400))
			elseif value then
				invalid("font-weight", numberToken(400))
			else
				fail("font-weight", "font-weight-or-parent-weight-required")
			end
		end
	end
	local parentSize = if parent then Typography.fontSize(parent) else context.initialFontSize
	local parentLineHeight = if parent
		then Typography.lineHeight(parent, context.parentMetrics)
		elseif context.parentMetrics and context.parentMetrics.normalLineHeight then context.initialFontSize
			* context.parentMetrics.normalLineHeight
		else nil
	if not result.unresolved["font-size"] then
		local tokens = properties["font-size"]
		local name = word(tokens)
		local invalidSize = name ~= nil and not sizeKeywords[name]
		local value: number? = nil
		if name == "medium" then
			value = context.initialFontSize
		elseif name and context.fontSizeKeywords then
			value = context.fontSizeKeywords[name]
		elseif not tokens then
			value = parentSize
		end
		if value == nil and tokens and not name then
			local options = lengths(context, parentSize, parentLineHeight, context.parentMetrics)
			options.percentageDimension = "length"
			options.percentageBasis = parentSize
			local measured, failure = Measurements.resolve(tokens, options)
			if measured and measured.dimension == "length" then
				value = Measurements.toScalar(measured, options)
			elseif measured and measured.dimension == "number" and measured.value == 0 then
				value = 0
			else
				fail("font-size", failure or "expected-font-length")
			end
		end
		if value and value < 0 and tokens and #tokens == 1 and tokens[1].kind == "function" then
			value = 0
		end
		if invalidSize or (value and value < 0) then
			invalid("font-size", pixels(context.initialFontSize))
		elseif value and value >= 0 and value < math.huge then
			properties["font-size"] = pixels(value)
		elseif not result.unresolved["font-size"] then
			fail("font-size", `font-size-context-required:{name or "relative length"}`)
		end
	end
	local currentMetrics = if metricsProvider then metricsProvider(result) else nil
	local size = Typography.fontSize(result)
	local options = lengths(context, size, nil, currentMetrics)
	if not result.unresolved["line-height"] then
		local tokens = properties["line-height"]
		if not tokens then
			properties["line-height"] = { { kind = "word", value = "normal" } }
		elseif word(tokens) ~= "normal" then
			if word(tokens) then
				invalid("line-height", { { kind = "word", value = "normal" } })
				tokens = properties["line-height"]
			end
			if word(tokens) == "normal" then
				-- Invalid variable substitution falls back through inheritance.
				properties["line-height"] = tokens
			else
				local lineOptions = table.clone(options)
				lineOptions.lineHeight = parentLineHeight
				lineOptions.percentageDimension = "length"
				lineOptions.percentageBasis = size
				local measured, failure = Measurements.resolve(tokens, lineOptions)
				if
					measured
					and measured.value < 0
					and #tokens == 1
					and tokens[1].kind == "function"
					and (measured.percentage or 0) == 0
				then
					measured.value = 0
				end
				if measured and measured.dimension == "number" and measured.value >= 0 then
					properties["line-height"] = numberToken(measured.value)
				elseif measured and measured.dimension == "length" then
					local value = Measurements.toScalar(measured, lineOptions)
					if value and value >= 0 then
						properties["line-height"] = pixels(value)
					else
						fail("line-height", "line-height-font-size-required")
					end
				else
					fail("line-height", failure or "invalid-line-height")
				end
			end
		end
	end
	options.lineHeight = Typography.lineHeight(result, currentMetrics)
	for _, property in { "letter-spacing", "word-spacing" } do
		local tokens = properties[property]
		if tokens and word(tokens) ~= "normal" and not result.unresolved[property] then
			local measured, failure = Measurements.resolve(tokens, options)
			if measured and measured.dimension == "length" and (measured.percentage or 0) == 0 then
				properties[property] = pixels(measured.value)
			elseif measured and measured.dimension == "number" and measured.value == 0 then
				properties[property] = pixels(0)
			else
				fail(property, failure or "spacing-metrics-required")
			end
		end
	end
	if not result.unresolved["tab-size"] then
		local tokens = properties["tab-size"] or numberToken(8)
		local measured, failure = Measurements.resolve(tokens, options)
		if measured then
			local value = measured.value
			if value < 0 and #tokens == 1 and tokens[1].kind == "function" then
				value = 0
			end
			if value < 0 or (measured.percentage or 0) ~= 0 then
				invalid("tab-size", numberToken(8))
			elseif measured.dimension == "number" then
				properties["tab-size"] = numberToken(value)
			elseif measured.dimension == "length" then
				-- Lengths compute before inheritance; a child's font must not
				-- reinterpret an inherited em/ch/lh expression.
				properties["tab-size"] = pixels(value)
			else
				invalid("tab-size", numberToken(8))
			end
		else
			fail("tab-size", failure or "tab-size-metrics-required")
		end
	end
	return result, currentMetrics
end

return Typography
