--!strict
-- Resolved CSSOM reads from committed layout and the active native timelines.
-- Unknown properties fail instead of returning plausible but invented values.
local Types = require(script.Parent.Types)
local BoxModel = require(script.Parent.BoxModel)
local Measurements = require(script.Parent.Measurements)
local Transforms = require(script.Parent.TransformValues)
local AnimationValues = require(script.Parent.AnimationValues)
local LogicalProperties = require(script.Parent.LogicalProperties)

export type Input = {
	style: Types.ComputedStyle,
	geometry: BoxModel.Geometry,
	metrics: BoxModel.Metrics,
	units: Measurements.Context,
	transform: (() -> Transforms.Value?)?,
	animation: ((string) -> (AnimationValues.Value?, boolean))?,
	opacity: number,
}
local ResolvedStyle = {}
local initials = { position = "static", ["box-sizing"] = "content-box" }
local function number(value: number): string
	assert(value == value and math.abs(value) < math.huge, "resolved-style-finite-number-required")
	-- CSSOM component serialization uses at most six decimal places, without
	-- exponent notation: https://drafts.csswg.org/cssom/#serialize-a-css-component-value
	local text = string.gsub(string.gsub(string.format("%.6f", value), "0+$", ""), "%.$", "")
	return if text == "-0" then "0" else text
end
local function px(value: number): string
	return number(value) .. "px"
end
local function keyword(input: Input, name: string): (string?, string?)
	local tokens = input.style.properties[name]
	if not tokens then
		return initials[name], if initials[name] then nil else "resolved-style-property-provider-required:" .. name
	end
	local result: string? = nil
	for _, token in tokens do
		if token.kind == "space" or token.kind == "comment" then
			continue
		end
		if result or token.kind ~= "word" then
			return nil, "resolved-style-keyword-provider-required:" .. name
		end
		result = string.lower(token.identifier or token.value)
	end
	return result, if result then nil else "resolved-style-keyword-provider-required:" .. name
end

type Provider = (Input) -> (string?, string?)
local providers: { [string]: Provider } = {}
providers.transform = function(input: Input): (string?, string?)
	local captured, context, failure = Transforms.capture(input.style, input.geometry, input.units)
	if not captured or not context then
		return nil, failure
	end
	local value: Transforms.Value = (if input.transform then input.transform() else nil) or captured
	if input.animation then
		local angle, contributed = input.animation("transform")
		if contributed then
			assert(type(angle) == "number", "animation-transform-angle-required")
			local functions: { Transforms.Function } = { { kind = "rotate", angle = angle } }
			value = { functions = functions, none = false }
		end
	end
	if value.none then
		return "none", nil
	end
	local matrix, reason = Transforms.matrix(value, context)
	if not matrix then
		return nil, reason
	end
	return "matrix(" .. table.concat({
		number(matrix.a),
		number(matrix.b),
		number(matrix.c),
		number(matrix.d),
		number(matrix.x),
		number(matrix.y),
	}, ", ") .. ")",
		nil
end
for _, property in { "width", "height" } do
	local name = property
	providers[name] = function(input: Input): (string?, string?)
		local g = input.geometry
		return px(
			if input.metrics.boxSizing == "border-box"
				then (if name == "width" then g.width else g.height)
				else (if name == "width" then g.contentWidth else g.contentHeight)
		),
			nil
	end
end
providers.opacity = function(input: Input): (string?, string?)
	local value = input.opacity
	if input.animation then
		local animated, contributed = input.animation("opacity")
		if contributed then
			assert(type(animated) == "number", "animation-opacity-number-required")
			value = animated
		end
	end
	return number(math.clamp(value, 0, 1)), nil
end
for _, side in { "top", "right", "bottom", "left" } do
	local edge = side
	providers["padding-" .. edge] = function(input: Input): (string?, string?)
		return px(input.metrics.padding[edge]), nil
	end
	providers["border-" .. edge .. "-width"] = function(input: Input): (string?, string?)
		return px(input.metrics.border[edge]), nil
	end
	local marginName = "margin-" .. edge
	providers[marginName] = function(input: Input): (string?, string?)
		local margin = input.metrics.margin[edge]
		return if margin.auto then nil else px(margin.value),
			if margin.auto then "resolved-auto-margin-provider-required:" .. marginName else nil
	end
end
for _, axis in { "inline-start", "inline-end", "block-start", "block-end" } do
	for _, family in { "padding", "margin", "border" } do
		local name = family .. "-" .. axis .. (if family == "border" then "-width" else "")
		providers[name] = function(input: Input): (string?, string?)
			local mapping, failure = LogicalProperties.names(input.style)
			if not mapping then return nil, failure end
			local physical = mapping[name]
			return providers[physical](input)
		end
	end
end
for property in initials do
	local name = property
	providers[name] = function(input: Input): (string?, string?)
		return keyword(input, name)
	end
end
local cssInitials: { [string]: string } = {
	translate = "none", rotate = "none", scale = "none",
	visibility = "visible", display = "inline", overflow = "visible", ["overflow-x"] = "visible", ["overflow-y"] = "visible",
	perspective = "none", filter = "none", ["backdrop-filter"] = "none", ["will-change"] = "auto", contain = "none",
	["animation-name"] = "none", ["animation-duration"] = "0s", ["animation-delay"] = "0s",
	["animation-play-state"] = "running", ["animation-timing-function"] = "ease",
	["animation-iteration-count"] = "1", ["animation-direction"] = "normal",
	["animation-fill-mode"] = "none", ["animation-timeline"] = "auto",
	["animation-range-start"] = "normal", ["animation-range-end"] = "normal",
	["animation-composition"] = "replace", ["transition-property"] = "all",
	["transition-duration"] = "0s", ["transition-delay"] = "0s",
	["transition-timing-function"] = "ease", ["transition-behavior"] = "normal",
}
local function serialize(tokens: { Types.ValueToken }): string
	local parts: { string } = {}
	for _, token in tokens do
		if token.kind == "comment" then continue end
		local value = token.value
		if token.kind == "dimension" then value ..= token.unit or ""
		elseif token.kind == "percentage" then value ..= "%"
		elseif token.kind == "function" then value ..= "(" .. serialize(token.children or {}) .. ")"
		elseif token.kind == "string" then value = '"' .. value .. '"' end
		table.insert(parts, value)
	end
	return table.concat(parts)
end
for property, initial in cssInitials do
	local name, fallback = property, initial
	providers[name] = function(input: Input): (string?, string?)
		local tokens = input.style.properties[name]
		return if tokens then serialize(tokens) else fallback, nil
	end
end
-- The DOM boundary advertises precisely these providers. The registry remains
-- the single authority for both named CSSOM access and value resolution.
local names: { string } = {}
for name in providers do
	table.insert(names, name)
end
table.sort(names)
ResolvedStyle.names = table.freeze(names)

function ResolvedStyle.read(input: Input, name: string): (string?, string?)
	if input.style.unresolved[name] then
		return nil, input.style.unresolved[name]
	end
	local provider = providers[name]
	if not provider then
		return nil, "resolved-style-property-provider-required:" .. name
	end
	return provider(input)
end
return ResolvedStyle
