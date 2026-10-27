--!strict

local Types = require(script.Parent.Types)
local BackgroundShorthand = require(script.Parent.BackgroundShorthand)
local TransitionShorthand = require(script.Parent.TransitionShorthand)
local AnimationShorthand = require(script.Parent.AnimationShorthand)
local TextDecorationShorthand = require(script.Parent.TextDecorationShorthand)
local FontShorthand = require(script.Parent.FontShorthand)
local FontVariantShorthand = require(script.Parent.FontVariantShorthand)
local GridShorthand = require(script.Parent.GridShorthand)
local GridLine = require(script.Parent.GridLine)
type Token = Types.ValueToken

local Shorthands = {}

local four: { [string]: { string } } = {
	padding = { "padding-top", "padding-right", "padding-bottom", "padding-left" },
	margin = { "margin-top", "margin-right", "margin-bottom", "margin-left" },
	inset = { "top", "right", "bottom", "left" },
	["border-width"] = { "border-top-width", "border-right-width", "border-bottom-width", "border-left-width" },
	["border-style"] = { "border-top-style", "border-right-style", "border-bottom-style", "border-left-style" },
	["border-color"] = { "border-top-color", "border-right-color", "border-bottom-color", "border-left-color" },
}

local two: { [string]: { string } } = {
	["padding-block"] = { "padding-block-start", "padding-block-end" },
	["padding-inline"] = { "padding-inline-start", "padding-inline-end" },
	["margin-block"] = { "margin-block-start", "margin-block-end" },
	["margin-inline"] = { "margin-inline-start", "margin-inline-end" },
	["inset-block"] = { "inset-block-start", "inset-block-end" },
	["inset-inline"] = { "inset-inline-start", "inset-inline-end" },
	["border-block-width"] = { "border-block-start-width", "border-block-end-width" },
	["border-inline-width"] = { "border-inline-start-width", "border-inline-end-width" },
	["border-block-style"] = { "border-block-start-style", "border-block-end-style" },
	["border-inline-style"] = { "border-inline-start-style", "border-inline-end-style" },
	["border-block-color"] = { "border-block-start-color", "border-block-end-color" },
	["border-inline-color"] = { "border-inline-start-color", "border-inline-end-color" },
	gap = { "row-gap", "column-gap" },
	overflow = { "overflow-x", "overflow-y" },
	["overscroll-behavior"] = { "overscroll-behavior-x", "overscroll-behavior-y" },
}

local flexTargets = { "flex-grow", "flex-shrink", "flex-basis" }
local flowTargets = { "flex-direction", "flex-wrap" }
local whitespaceTargets = { "white-space-collapse", "text-wrap-mode", "white-space-trim" }
local wrapTargets = { "text-wrap-mode", "text-wrap-style" }
local legacyWhitespace: { [string]: { string } } = {
	normal = { "collapse", "wrap" },
	pre = { "preserve", "nowrap" },
	["pre-wrap"] = { "preserve", "wrap" },
	["pre-line"] = { "preserve-breaks", "wrap" },
}
local collapseValues: { [string]: boolean } = {
	collapse = true,
	preserve = true,
	["preserve-breaks"] = true,
	["preserve-spaces"] = true,
	["break-spaces"] = true,
	discard = true,
}
local wrapStyles: { [string]: boolean } = {
	auto = true,
	balance = true,
	stable = true,
	pretty = true,
	["avoid-short-last-line"] = true,
}

local corners =
	{ "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius" }
local borderStyles: { [string]: boolean } = {
	none = true,
	hidden = true,
	dotted = true,
	dashed = true,
	solid = true,
	double = true,
	groove = true,
	ridge = true,
	inset = true,
	outset = true,
}
local widths: { [string]: boolean } = { thin = true, medium = true, thick = true }
local wide: { [string]: boolean } =
	{ initial = true, inherit = true, unset = true, revert = true, ["revert-layer"] = true }

local borders: { [string]: { string } } = {
	border = { "border-top", "border-right", "border-bottom", "border-left" },
	["border-top"] = { "border-top" },
	["border-right"] = { "border-right" },
	["border-bottom"] = { "border-bottom" },
	["border-left"] = { "border-left" },
	["border-block"] = { "border-block-start", "border-block-end" },
	["border-inline"] = { "border-inline-start", "border-inline-end" },
	["border-block-start"] = { "border-block-start" },
	["border-block-end"] = { "border-block-end" },
	["border-inline-start"] = { "border-inline-start" },
	["border-inline-end"] = { "border-inline-end" },
	outline = { "outline" },
}

local function significant(tokens: { Token }): { Token }
	local result = {}
	for _, token in tokens do
		if token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(result, token)
		end
	end
	return result
end

local function targets(property: string): { string }?
	if GridShorthand.targets[property] then
		return GridShorthand.targets[property]
	elseif property == "transition" then
		return TransitionShorthand.targets
	elseif property == "animation" then
		return AnimationShorthand.targets
	elseif property == "background" then
		return BackgroundShorthand.targets
	elseif property == "text-decoration" then
		return TextDecorationShorthand.targets
	elseif property == "font" then
		return FontShorthand.targets
	elseif property == "font-variant" then
		return FontVariantShorthand.targets
	elseif property == "flex" then
		return flexTargets
	elseif property == "flex-flow" then
		return flowTargets
	elseif property == "white-space" then
		return whitespaceTargets
	elseif property == "text-wrap" then
		return wrapTargets
	end
	if four[property] then
		return four[property]
	end
	if two[property] then
		return two[property]
	end
	if property == "border-radius" then
		return corners
	end
	local edges = borders[property]
	if edges then
		local result = {}
		for _, edge in edges do
			for _, suffix in { "width", "style", "color" } do
				table.insert(result, edge .. "-" .. suffix)
			end
		end
		-- The CSS border shorthand also resets border-image.
		if property == "border" then
			for _, suffix in { "source", "slice", "width", "outset", "repeat" } do
				table.insert(result, "border-image-" .. suffix)
			end
		end
		return result
	end
	return nil
end

local function flex(parts: { Token }): ({ { Token } }?, string?)
	local function number(value: string): { Token }
		return { { kind = "number", value = value } }
	end
	local function basis(): { Token }
		return { { kind = "percentage", value = "0" } }
	end
	local auto: { Token } = { { kind = "word", value = "auto" } }
	if #parts == 1 and parts[1].kind == "word" then
		local word = string.lower(parts[1].value)
		if word == "none" then
			return { number("0"), number("0"), auto }, nil
		elseif word == "auto" then
			return { number("1"), number("1"), auto }, nil
		end
	end
	local numbers: { Token } = {}
	local size: Token? = nil
	local numberGroupEnded = false
	for _, token in parts do
		if token.kind == "number" then
			local value = tonumber(token.value)
			if not value or value < 0 or value == math.huge then
				return nil, "invalid-flex-factor"
			end
			if #numbers == 2 and not size and value == 0 then
				size = { kind = "dimension", value = "0", unit = "px" }
				numberGroupEnded = true
			elseif #numbers >= 2 or numberGroupEnded then
				return nil, "invalid-flex-factor-order"
			else
				table.insert(numbers, token)
			end
		elseif token.kind == "dimension" or token.kind == "percentage" or token.kind == "word" then
			if size then
				return nil, "multiple-flex-bases"
			end
			size = token
			numberGroupEnded = #numbers > 0
		else
			return nil, "flex-math-type-resolution-pending"
		end
	end
	if #parts == 0 or #parts > 3 then
		return nil, "empty-flex-shorthand"
	end
	return {
		if numbers[1] then { numbers[1] } else number("1"),
		if numbers[2] then { numbers[2] } else number("1"),
		if size then { size :: Token } else basis(),
	},
		nil
end

local function usesVariables(tokens: { Token }): boolean
	for _, token in tokens do
		if token.kind == "function" and string.lower(token.value) == "var" then
			return true
		end
		if token.children and usesVariables(token.children) then
			return true
		end
	end
	return false
end

function Shorthands.expand(
	declaration: Types.Declaration,
	metadata: { [string]: Types.PropertyMetadata }?
): { Types.Declaration }
	local all = if metadata then metadata.all else nil
	local names = if declaration.property == "all"
		then (if all then all.longhands else nil)
		else targets(declaration.property)
	if not names then
		return { declaration }
	end
	local result = {}
	local static = not usesVariables(declaration.tokens)
	for _, name in names do
		if
			declaration.property == "all"
			and (name == "all" or name == "direction" or name == "unicode-bidi" or name:sub(1, 2) == "--")
		then
			continue
		end
		local copy = table.clone(declaration)
		copy.property = name
		copy.shorthand = { property = declaration.property, target = name }
		-- A successful variable-free expansion is independent of a node or its
		-- environment. Prepare it with the stylesheet/inline packet once rather
		-- than parsing the same source on every computed-value pass. Pending or
		-- invalid values retain the ordinary diagnostics and runtime resolver.
		if static then
			local tokens, failure, pending = Shorthands.resolve(declaration.property, name, declaration.tokens)
			if tokens and not failure and not pending then
				copy.tokens = tokens
				copy.shorthand = nil
			end
		end
		table.insert(result, copy)
	end
	return result
end

local function selectFour(parts: { Token }, index: number): Token?
	if #parts < 1 or #parts > 4 then
		return nil
	end
	if index == 1 then
		return parts[1]
	end
	if index == 2 then
		return parts[2] or parts[1]
	end
	if index == 3 then
		return parts[3] or parts[1]
	end
	return parts[4] or parts[2] or parts[1]
end

local function borderParts(parts: { Token }, outline: boolean?): ({ Token }?, { Token }?, { Token }?)
	if #parts < 1 or #parts > 3 then
		return nil, nil, nil
	end
	local width: Token? = nil
	local style: Token? = nil
	local color: Token? = nil
	for _, token in parts do
		local word = if token.kind == "word" then string.lower(token.value) else ""
		local functionName = string.lower(token.value)
		if outline and word == "hidden" then
			return nil, nil, nil
		end
		if borderStyles[word] or (outline and word == "auto") then
			if style then
				return nil, nil, nil
			end
			style = token
		elseif
			widths[word]
			or token.kind == "dimension"
			or (token.kind == "number" and tonumber(token.value) == 0)
			or (
				token.kind == "function"
				and (
					functionName == "calc"
					or functionName == "min"
					or functionName == "max"
					or functionName == "clamp"
				)
			)
		then
			if width then
				return nil, nil, nil
			end
			width = token
		else
			if color then
				return nil, nil, nil
			end
			color = token
		end
	end
	return { width or { kind = "word", value = "initial" } }, { style or { kind = "word", value = "initial" } }, {
		color or { kind = "word", value = "initial" },
	}
end

local function textWrapping(property: string, target: string, parts: { Token }): ({ Token }?, string?)
	local values: { [string]: string } = {
		["white-space-collapse"] = "collapse",
		["text-wrap-mode"] = "wrap",
		["text-wrap-style"] = "auto",
		["white-space-trim"] = "none",
	}
	local alias = if property == "white-space"
			and #parts == 1
			and parts[1].kind == "word"
		then legacyWhitespace[string.lower(parts[1].value)]
		else nil
	if alias then
		values["white-space-collapse"], values["text-wrap-mode"] = alias[1], alias[2]
	else
		local seen: { [string]: boolean } = {}
		local trimming: { string } = {}
		if #parts == 0 then
			return nil, `empty-{property}-shorthand`
		end
		for _, token in parts do
			local name = if token.kind == "word" then string.lower(token.value) else ""
			local selected: string?
			if name == "wrap" or name == "nowrap" then
				selected = "text-wrap-mode"
			elseif property == "white-space" and collapseValues[name] then
				selected = "white-space-collapse"
			elseif property == "text-wrap" and wrapStyles[name] then
				selected = "text-wrap-style"
			elseif
				property == "white-space"
				and (name == "none" or name == "discard-before" or name == "discard-after" or name == "discard-inner")
			then
				if seen[name] or (name == "none" and #trimming > 0) or seen.none then
					return nil, "invalid-white-space-trim-combination"
				end
				seen[name] = true
				table.insert(trimming, name)
				continue
			else
				return nil, `invalid-{property}-keyword:{token.value}`
			end
			if not selected then
				return nil, `invalid-{property}-component`
			end
			if seen[selected] then
				return nil, `duplicate-{property}-component:{selected}`
			end
			seen[selected] = true
			values[selected] = name
		end
		if #trimming > 0 then
			local result: { Token } = {}
			for _, name in trimming do
				table.insert(result, { kind = "word", value = name })
			end
			if target == "white-space-trim" then
				return result, nil
			end
		end
	end
	return { { kind = "word", value = values[target] } }, nil
end

local function resolve(property: string, target: string, tokens: { Token }): ({ Token }?, string?)
	local parts = significant(tokens)
	if #parts == 1 and parts[1].kind == "word" and wide[string.lower(parts[1].identifier or parts[1].value)] then
		return parts, nil
	end
	if property == "all" then
		return nil, "all-requires-css-wide-keyword"
	end
	if property == "transition" then
		return TransitionShorthand.resolve(target, parts)
	elseif property == "animation" then
		return AnimationShorthand.resolve(target, parts)
	elseif property == "background" then
		return BackgroundShorthand.resolve(target, parts)
	elseif property == "text-decoration" then
		return TextDecorationShorthand.resolve(target, parts)
	elseif property == "font" then
		return FontShorthand.resolve(target, parts)
	elseif property == "font-variant" then
		return FontVariantShorthand.resolve(target, parts)
	end
	if GridShorthand.targets[property] then
		return GridShorthand.resolve(property, target, parts)
	end
	if property == "white-space" or property == "text-wrap" then
		return textWrapping(property, target, parts)
	end
	if property == "flex" then
		local values, failure = flex(parts)
		local index = table.find(flexTargets, target)
		return if values and index then values[index] else nil, failure
	elseif property == "flex-flow" then
		local direction = "row"
		local wrap = "nowrap"
		local gotDirection, gotWrap = false, false
		if #parts < 1 or #parts > 2 then
			return nil, "invalid-flex-flow"
		end
		for _, token in parts do
			local name = if token.kind == "word" then string.lower(token.value) else ""
			if name == "row" or name == "row-reverse" or name == "column" or name == "column-reverse" then
				if gotDirection then
					return nil, "duplicate-flex-direction"
				end
				direction, gotDirection = name, true
			elseif name == "nowrap" or name == "wrap" or name == "wrap-reverse" then
				if gotWrap then
					return nil, "duplicate-flex-wrap"
				end
				wrap, gotWrap = name, true
			else
				return nil, "invalid-flex-flow-keyword"
			end
		end
		return { { kind = "word", value = if target == "flex-direction" then direction else wrap } }, nil
	end
	local edges = four[property]
	if edges then
		local index = table.find(edges, target)
		local token = if index then selectFour(parts, index) else nil
		return if token then { token } else nil, if token then nil else "invalid-four-side-shorthand"
	end
	local pair = two[property]
	if pair then
		if #parts < 1 or #parts > 2 then
			return nil, "invalid-two-side-shorthand"
		end
		return { if target == pair[1] then parts[1] else (parts[2] or parts[1]) }, nil
	end
	if property == "border-radius" then
		local x: { Token } = {}
		local y: { Token }? = nil
		for _, token in parts do
			if token.kind == "operator" and token.value == "/" then
				if y then
					return nil, "invalid-radius-slash"
				end
				y = {}
			elseif y then
				table.insert(y, token)
			else
				table.insert(x, token)
			end
		end
		local index = table.find(corners, target)
		if not index then
			return nil, "unknown-radius-corner"
		end
		local horizontal, vertical = selectFour(x, index), selectFour(y or x, index)
		if not horizontal or not vertical then
			return nil, "invalid-radius-shorthand"
		end
		return { horizontal, vertical }, nil
	end
	if borders[property] then
		local width, style, color = borderParts(parts, property == "outline")
		if not width or not style or not color then
			return nil, "invalid-border-shorthand"
		end
		if target:sub(1, 13) == "border-image-" then
			return { { kind = "word", value = "initial" } }, nil
		end
		if target:sub(-6) == "-width" then
			return width, nil
		end
		if target:sub(-6) == "-style" then
			return style, nil
		end
		return color, nil
	end
	return nil, `unsupported-shorthand:{property}`
end

function Shorthands.resolve(property: string, target: string, tokens: { Token }): ({ Token }?, string?, boolean)
	local value, failure = resolve(property, target, tokens)
	return value,
		failure,
		GridLine.pending(failure)
			or failure == "flex-math-type-resolution-pending"
			or failure == "background-shorthand-provider-required"
			or failure == "transition-shorthand-provider-required"
			or failure == "animation-shorthand-provider-required"
			or failure == "animation-identifier-metadata-required"
			or (failure ~= nil and failure:sub(1, #"animation-number-computation-pending:") == "animation-number-computation-pending:")
			or failure == "text-decoration-shorthand-provider-required"
			or failure == "font-shorthand-provider-required"
			or failure == "font-system-provider-required"
			or failure == "font-variant-shorthand-provider-required"
			or (failure ~= nil and failure:sub(1, #"font-shorthand-computation-pending:") == "font-shorthand-computation-pending:")
			or (failure ~= nil and failure:sub(1, #"text-decoration-shorthand-computation-pending:") == "text-decoration-shorthand-computation-pending:")
			or failure == "easing-provider-required"
			or failure == "easing-budget-provider-required"
			or (failure ~= nil and failure:sub(1, 27) == "easing-computation-pending:")
			or (failure ~= nil and failure:sub(1, 36) == "transition-time-computation-pending:")
end

return Shorthands
