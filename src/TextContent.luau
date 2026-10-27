--!strict

local TextContent = {}
local unicodeBreaks = { utf8.char(0x85), utf8.char(0x2028), utf8.char(0x2029) }

-- Unicode BK/NL boundaries remain forced regardless of CSS white-space.
-- LF/CR document segment normalization is handled separately by Whitespace.
function TextContent.isUnicodeForcedBreak(codepoint: number): boolean
	return codepoint == 0xB or codepoint == 0xC or codepoint == 0x85 or codepoint == 0x2028 or codepoint == 0x2029
end

function TextContent.hasHardBreak(text: string): boolean
	if text:find("[\r\n\f\v]") then
		return true
	end
	for _, character in unicodeBreaks do
		if text:find(character, 1, true) then
			return true
		end
	end
	return false
end

-- Raw tab and line-boundary controls must be consumed by inline formatting.
-- A synthesized visible control glyph uses its rendered character instead.
function TextContent.validateSingleLine(text: string): string?
	if not utf8.len(text) then
		return "invalid-text-utf8"
	end
	if TextContent.hasHardBreak(text) or text:find("\t", 1, true) then
		return "text-line-layout-required"
	end
	return nil
end

return TextContent
