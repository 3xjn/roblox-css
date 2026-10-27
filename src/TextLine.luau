--!strict

local Types = require(script.Parent.Types)
local Fonts = require(script.Parent.Fonts)
local Typography = require(script.Parent.Typography)
local FontFeatures = require(script.Parent.FontFeatures)
local TextMeasurement = require(script.Parent.TextMeasurement)
local Whitespace = require(script.Parent.Whitespace)
local LineWhitespace = require(script.Parent.LineWhitespace)
local LineBox = require(script.Parent.LineBox)
local SceneTypes = require(script.Parent.SceneTypes)

-- All dimensions are CSS pixels, for the exact native face/size/text request.
-- nativeBaseline is measured from the top of an unwrapped, top-aligned native
-- TextLabel of nativeHeight. Bounds alone cannot supply this calibration.
-- advance is a shaped inline advance, not an ink/bounds width. Its source must
-- establish agreement with native shaping, including preserved spaces.
export type Geometry =
	{ advance: number, ascent: number, descent: number, nativeBaseline: number, nativeHeight: number }
export type GeometryProvider = (Types.ComputedStyle, string, TextMeasurement.Shape, Vector2) -> (Geometry?, string?)
export type Context = {
	width: number,
	fonts: Fonts.Provider,
	fontMetrics: Typography.Metrics?,
	measureText: TextMeasurement.Reader?,
	geometry: GeometryProvider?,
	-- Explicit platform line alignment, without claiming CSS baseline metrics.
	nativeTextLine: boolean?,
	-- A paragraph formatter may select a legal, intrinsically overflowing line.
	selectedLine: boolean?,
	ending: LineWhitespace.Ending?,
}
export type Result = { advance: number, height: number, baseline: number?, runs: { SceneTypes.GlyphRun } }

local TextLine = {}
local unsupported: { [string]: string } = {
	["text-transform"] = "none",
	["text-indent"] = "0",
	["text-overflow"] = "clip",
	["text-shadow"] = "none",
	["writing-mode"] = "horizontal-tb",
	["unicode-bidi"] = "normal",
}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function keyword(style: Types.ComputedStyle, property: string, initial: string): (string?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local tokens = style.properties[property]
	if not tokens then
		return initial, nil
	end
	if #tokens == 1 and tokens[1].kind == "word" then
		return string.lower(tokens[1].value), nil
	end
	return nil, `text-line-provider-required:{property}`
end

-- One leaf formatting context which needs no soft or forced line break.
-- Native shaping measures the entire processed string, preserving kerning and
-- ligatures. It never sums independently measured characters or words.
function TextLine.resolve(
	node: Types.Node,
	style: Types.ComputedStyle,
	atoms: { Whitespace.Atom },
	context: Context
): (Result?, string?)
	if not finite(context.width) or context.width < 0 then
		return nil, "invalid-text-line-width"
	end
	local trimmed, trimFailure = LineWhitespace.trimStart(atoms)
	if not trimmed then
		return nil, trimFailure
	end
	local line, endFailure = LineWhitespace.trimEnd(trimmed)
	if not line then
		return nil, endFailure
	end
	local pieces: { string } = {}
	local wrap = false
	for _, atom in line do
		if atom.discarded then
			continue
		end
		if atom.source ~= node then
			return nil, "mixed-inline-text-source-provider-required"
		end
		if atom.kind == "tab" then
			return nil, "text-line-tab-placement-provider-required"
		elseif atom.kind == "bidi" then
			return nil, "text-line-bidi-control-provider-required"
		end
		if atom.policy.wrap == "wrap" then
			wrap = true
			if not Whitespace.usesNormalWrapping(atom.policy.wrapStyle) then
				return nil, "text-line-wrap-style-provider-required"
			end
		end
		table.insert(pieces, atom.text)
	end
	local text = table.concat(pieces)
	if text == "" then
		return { advance = 0, height = 0, runs = {} }, nil
	end
	if #node.children > 0 then
		return nil, "mixed-inline-content-provider-required"
	end
	local ending = context.ending or "end"
	local hanging, hangingFailure = LineWhitespace.classifyHanging(line, ending)
	if not hanging then
		return nil, hangingFailure
	end
	if next(hanging) ~= nil then
		return nil, "text-line-hanging-width-provider-required"
	end
	for property, initial in unsupported do
		local tokens = style.properties[property]
		if property == "text-indent" and tokens and #tokens == 1 then
			local token = tokens[1]
			if
				(token.kind == "number" or token.kind == "dimension" or token.kind == "percentage")
				and tonumber(token.value) == 0
				and not style.unresolved[property]
			then
				continue
			end
		end
		local value, failure = keyword(style, property, initial)
		if value ~= initial then
			return nil, failure or `text-line-provider-required:{property}`
		end
	end
	for _, property in { "text-decoration", "text-align-all" } do
		if style.properties[property] or style.unresolved[property] then
			return nil, `text-line-unexpanded-shorthand:{property}`
		end
	end
	for _, property in { "letter-spacing", "word-spacing" } do
		local tokens = style.properties[property]
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
		if tokens then
			local normal = #tokens == 1 and tokens[1].kind == "word" and tokens[1].value == "normal"
			local zero = #tokens == 1
				and (tokens[1].kind == "number" or tokens[1].kind == "dimension")
				and tonumber(tokens[1].value) == 0
			if not normal and not zero then
				return nil, `text-line-spacing-provider-required:{property}`
			end
		end
	end
	local direction, directionFailure = keyword(style, "direction", "ltr")
	if direction ~= "ltr" then
		return nil, directionFailure or "text-line-direction-provider-required"
	end
	local align, alignFailure = keyword(style, "text-align", "start")
	local last, lastFailure = keyword(style, "text-align-last", "auto")
	if not align or not last then
		return nil, alignFailure or lastFailure
	end
	if ending == "soft" then
		-- text-align-last applies only at a forced break or paragraph end.
	elseif last ~= "auto" then
		align = last
	elseif align == "justify" then
		align = "start"
	end
	if align ~= "start" and align ~= "end" and align ~= "left" and align ~= "right" and align ~= "center" then
		return nil, "text-line-alignment-provider-required"
	end
	local font, fontFailure = context.fonts:resolveStyle(style)
	if not font then
		return nil, fontFailure
	end
	local size = Typography.fontSize(style)
	local lineHeight = Typography.lineHeight(style, context.fontMetrics)
	if not size or not finite(size) or size < 0 or not lineHeight or not finite(lineHeight) or lineHeight < 0 then
		return nil, "text-line-computed-font-metrics-required"
	end
	local features, featureFailure = FontFeatures.resolve(style, font.defaultFeatures)
	if not features then
		return nil, featureFailure
	end
	local shape: TextMeasurement.Shape = { font = font.font, size = size, features = features, direction = direction }
	if not context.measureText then
		return nil, "text-line-measurement-reader-required"
	end
	if not context.geometry and not context.nativeTextLine then
		return nil, "text-line-native-baseline-calibration-required"
	end
	local bounds, measureFailure = context.measureText(text, shape)
	if not bounds then
		return nil, measureFailure or "text-line-measurement-unavailable"
	end
	if not finite(bounds.X) or not finite(bounds.Y) or bounds.X < 0 or bounds.Y < 0 then
		return nil, "invalid-text-line-measurement"
	end
	if not context.geometry then
		if wrap and bounds.X > context.width and not context.selectedLine then
			return nil, "text-line-wrapping-provider-required"
		end
		local x = if align == "center"
			then (context.width - bounds.X) / 2
			elseif align == "end" or align == "right" then context.width - bounds.X
			else 0
		return {
			advance = bounds.X,
			height = lineHeight,
			runs = {
				{
					key = "text",
					source = node,
					text = text,
					x = x,
					y = 0,
					width = bounds.X,
					height = lineHeight,
					verticalAlign = "center",
				},
			},
		},
			nil
	end
	local geometry, geometryFailure = context.geometry(style, text, shape, bounds)
	if not geometry then
		return nil, geometryFailure or "text-line-native-geometry-unavailable"
	end
	for _, value in
		{ geometry.advance, geometry.ascent, geometry.descent, geometry.nativeBaseline, geometry.nativeHeight }
	do
		if not finite(value) or value < 0 then
			return nil, "invalid-text-line-native-geometry"
		end
	end
	if wrap and geometry.advance > context.width and not context.selectedLine then
		return nil, "text-line-wrapping-provider-required"
	end
	local metrics: LineBox.Metrics = { ascent = geometry.ascent, descent = geometry.descent, lineHeight = lineHeight }
	local layout, layoutFailure = LineBox.resolve(metrics, { { metrics = metrics } })
	if not layout then
		return nil, layoutFailure
	end
	local x = if align == "center"
		then (context.width - geometry.advance) / 2
		elseif align == "end" or align == "right" then context.width - geometry.advance
		else 0
	local y = layout.baseline - geometry.nativeBaseline
	if not finite(x) or not finite(y) then
		return nil, "text-line-geometry-overflow"
	end
	return {
		advance = geometry.advance,
		height = layout.height,
		baseline = layout.baseline,
		runs = {
			{
				key = "text",
				source = node,
				text = text,
				x = x,
				y = y,
				width = bounds.X,
				height = geometry.nativeHeight,
			},
		},
	},
		nil
end

return TextLine
