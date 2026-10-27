--!strict

local Types = require(script.Parent.Types)
local NativeColors = require(script.Parent.NativeColors)

export type Decoration = { underline: boolean, strike: boolean }
local TextDecoration = {}

local function word(tokens: { Types.ValueToken }?): string?
	return if tokens and #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

-- Native font decoration metrics only. Explicit CSS geometry needs a separate
-- backend; do not silently replace a requested offset or thickness with auto.
function TextDecoration.resolve(
	style: Types.ComputedStyle,
	foreground: Types.RgbaColor,
	systemColors: { [string]: Types.RgbaColor }?
): (Decoration?, string?)
	if style.properties["text-decoration"] or style.unresolved["text-decoration"] then
		return nil, "unexpanded-text-decoration-shorthand"
	end
	if style.unresolved["text-decoration-line"] then
		return nil, style.unresolved["text-decoration-line"]
	end
	local tokens = style.properties["text-decoration-line"]
	if not tokens or word(tokens) == "none" then
		return nil, nil
	end
	local result: Decoration = { underline = false, strike = false }
	local count = 0
	for _, token in tokens do
		if token.kind == "space" or token.kind == "comment" then
			continue
		end
		local name = if token.kind == "word" then string.lower(token.value) else ""
		if name == "underline" and not result.underline then
			result.underline = true
		elseif name == "line-through" and not result.strike then
			result.strike = true
		else
			return nil, `text-decoration-line-provider-required:{name}`
		end
		count += 1
	end
	if count == 0 then
		return nil, "invalid-text-decoration-line"
	end
	local defaults: { [string]: string } = {
		["text-decoration-style"] = "solid",
		["text-decoration-thickness"] = "auto",
	}
	if result.underline then
		defaults["text-underline-offset"] = "auto"
		defaults["text-underline-position"] = "auto"
		defaults["text-decoration-skip-ink"] = "auto"
	end
	for property, initial in defaults do
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
		local value = style.properties[property]
		if value and word(value) ~= initial then
			return nil, `text-decoration-geometry-provider-required:{property}`
		end
	end
	if style.unresolved["text-decoration-color"] then
		return nil, style.unresolved["text-decoration-color"]
	end
	local colorTokens = style.properties["text-decoration-color"]
	if colorTokens and word(colorTokens) ~= "currentcolor" then
		local color, failure =
			NativeColors.resolve(colorTokens, { currentColor = foreground, systemColors = systemColors })
		local textColor, textFailure = NativeColors.fromRgba(foreground)
		if not color or not textColor then
			return nil, failure or textFailure
		end
		if color.value ~= textColor.value or color.transparency ~= textColor.transparency then
			return nil, "text-decoration-independent-color-provider-required"
		end
	end
	return result, nil
end

-- User text is always literal. Only this module supplies markup tags; an
-- entity already present in the source must remain an entity in the output.
function TextDecoration.markup(text: string, decoration: Decoration): string
	local escaped = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
	if decoration.strike then
		escaped = `<s>{escaped}</s>`
	end
	if decoration.underline then
		escaped = `<u>{escaped}</u>`
	end
	return escaped
end

return TextDecoration
