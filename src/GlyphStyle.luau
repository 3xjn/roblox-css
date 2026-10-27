--!strict

local Types = require(script.Parent.Types)
local Fonts = require(script.Parent.Fonts)
local Typography = require(script.Parent.Typography)
local Colors = require(script.Parent.Colors)
local NativeColors = require(script.Parent.NativeColors)
local FontFeatures = require(script.Parent.FontFeatures)
local TextDecoration = require(script.Parent.TextDecoration)

export type Style = {
	font: Font,
	size: number,
	color: NativeColors.Color,
	features: string,
	direction: string,
	decoration: TextDecoration.Decoration?,
}
export type Context = { inheritedColor: Types.RgbaColor?, systemColors: { [string]: Types.RgbaColor }? }

local GlyphStyle = {}
local canvasText: { Types.ValueToken } = { { kind = "word", value = "canvastext" } }
local defaults: { [string]: string } = {
	["font-variation-settings"] = "normal",
	["font-size-adjust"] = "none",
	["font-variant-caps"] = "normal",
	["font-variant-position"] = "normal",
	["font-variant-east-asian"] = "normal",
	["font-variant-alternates"] = "normal",
	["font-variant-emoji"] = "normal",
	["font-stretch"] = "normal",
	["font-width"] = "normal",
	["font-language-override"] = "normal",
	["font-palette"] = "normal",
	["unicode-bidi"] = "normal",
	["writing-mode"] = "horizontal-tb",
}

local function word(tokens: { Types.ValueToken }?): string?
	return if tokens and #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

-- Glyph paint includes bounded native default decorations. Inline layout owns
-- whitespace, wrapping, alignment, baselines, line height and run placement.
function GlyphStyle.resolve(style: Types.ComputedStyle, fonts: Fonts.Provider, context: Context): (Style?, string?)
	for _, property in { "font", "font-variant" } do
		-- Older metadata can retain a redundant `font-variant: normal` value.
		-- Authored shorthands expand to variant leaves before reaching paint.
		local metadataDefault = property == "font-variant"
			and word(style.properties[property]) == "normal"
			and not style.unresolved[property]
		if style.properties[property] and not metadataDefault then
			return nil, `unexpanded-font-shorthand:{property}`
		end
	end
	for property, initial in defaults do
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
		local tokens = style.properties[property]
		local isNormalWidth = (property == "font-width" or property == "font-stretch")
			and tokens
			and #tokens == 1
			and tokens[1].kind == "percentage"
			and tonumber(tokens[1].value) == 100
		if tokens and word(tokens) ~= initial and not isNormalWidth then
			return nil, `glyph-backend-required:{property}`
		end
	end
	for _, property in { "letter-spacing", "word-spacing" } do
		local tokens = style.properties[property]
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
		if tokens and word(tokens) ~= "normal" then
			if
				#tokens ~= 1
				or (tokens[1].kind ~= "dimension" and tokens[1].kind ~= "number")
				or tonumber(tokens[1].value) ~= 0
			then
				return nil, `glyph-spacing-backend-required:{property}`
			end
		end
	end
	local face, fontFailure = fonts:resolveStyle(style)
	if not face then
		return nil, fontFailure
	end
	local size = Typography.fontSize(style)
	if size == nil or size < 0 or size == math.huge or size ~= size then
		return nil, "computed-font-size-required"
	end
	local features, featureFailure = FontFeatures.resolve(style, face.defaultFeatures)
	if not features then
		return nil, featureFailure
	end
	if style.unresolved.color then
		return nil, `color:{style.unresolved.color}`
	end
	local foreground, colorFailure = Colors.resolve(style.properties.color or canvasText, {
		currentColor = context.inheritedColor,
		systemColors = context.systemColors,
	})
	if not foreground then
		return nil, colorFailure
	end
	local color, gamutFailure = NativeColors.fromRgba(foreground)
	if not color then
		return nil, gamutFailure
	end
	if style.unresolved.direction then
		return nil, style.unresolved.direction
	end
	local direction = word(style.properties.direction) or "ltr"
	if direction ~= "ltr" and direction ~= "rtl" then
		return nil, `unsupported-text-direction:{direction}`
	end
	local decoration, decorationFailure = TextDecoration.resolve(style, foreground, context.systemColors)
	if decorationFailure then
		return nil, decorationFailure
	end
	return {
		font = face.font,
		size = size,
		color = color,
		features = features,
		direction = direction,
		decoration = decoration,
	},
		nil
end

return GlyphStyle
