--!strict

local Types = require(script.Parent.Types)
type Token = Types.ValueToken
local FontVariantShorthand = {}
FontVariantShorthand.targets = {
	"font-variant-ligatures",
	"font-variant-position",
	"font-variant-caps",
	"font-variant-numeric",
	"font-variant-alternates",
	"font-variant-east-asian",
	"font-variant-emoji",
}
local keywords: { [string]: { property: string, slot: string } } = {}
local function group(property: string, slot: string, words: string)
	for name in words:gmatch("%S+") do
		keywords[name] = { property = "font-variant-" .. property, slot = slot }
	end
end
group("caps", "caps", "small-caps all-small-caps petite-caps all-petite-caps unicase titling-caps")
group("position", "position", "sub super")
group("numeric", "figure", "lining-nums oldstyle-nums")
group("numeric", "spacing", "proportional-nums tabular-nums")
group("numeric", "fraction", "diagonal-fractions stacked-fractions")
group("numeric", "ordinal", "ordinal")
group("numeric", "zero", "slashed-zero")
group("ligatures", "common", "common-ligatures no-common-ligatures")
group("ligatures", "discretionary", "discretionary-ligatures no-discretionary-ligatures")
group("ligatures", "historical", "historical-ligatures no-historical-ligatures")
group("ligatures", "contextual", "contextual no-contextual")
group("east-asian", "form", "jis78 jis83 jis90 jis04 simplified traditional")
group("east-asian", "width", "full-width proportional-width")
group("east-asian", "ruby", "ruby")
group("alternates", "historical-forms", "historical-forms")
group("emoji", "emoji", "text emoji unicode")

function FontVariantShorthand.resolve(target: string, parts: { Token }): ({ Token }?, string?)
	if not table.find(FontVariantShorthand.targets, target) then
		return nil, "unknown-font-variant-target"
	end
	if #parts == 0 then
		return nil, "empty-font-variant-shorthand"
	end
	if #parts == 1 and parts[1].kind == "word" then
		local name = string.lower(parts[1].value)
		if name == "normal" or name == "none" then
			return if name == "none" and target == "font-variant-ligatures"
				then { parts[1] }
				else { { kind = "word", value = "initial" } },
				nil
		end
	end
	local values: { [string]: { Token } } = {}
	local slots: { [string]: boolean } = {}
	local previous: string? = nil
	local closed: { [string]: boolean } = {}
	for _, token in parts do
		if token.kind == "function" or token.kind == "raw" or token.value:find("\\") then
			return nil, "font-variant-shorthand-provider-required"
		end
		local entry = if token.kind == "word" then keywords[string.lower(token.value)] else nil
		if not entry or slots[entry.slot] then
			return nil, "invalid-font-variant-combination"
		end
		if previous and previous ~= entry.property then
			closed[previous] = true
		end
		if closed[entry.property] then
			return nil, "noncontiguous-font-variant-component"
		end
		previous = entry.property
		slots[entry.slot] = true
		local list = values[entry.property] or {}
		table.insert(list, token)
		values[entry.property] = list
	end
	return values[target] or { { kind = "word", value = "initial" } }, nil
end

return FontVariantShorthand
