--!strict

local Types = require(script.Parent.Types)
local Cascade = require(script.Parent.Cascade)

local LogicalProperties = {}

export type Lookup = (string) -> ({ Types.ValueToken }?, string?, string?)

-- Only the three supported writing modes and two directions reach this cache.
local mappings: { [string]: { [string]: string } } = {}

local function word(style: Types.ComputedStyle, property: string, fallback: string): string?
	local tokens = style.properties[property]
	if not tokens then
		return fallback
	end
	if #tokens == 1 and tokens[1].kind == "word" then
		return string.lower(tokens[1].value)
	end
	return nil
end

function LogicalProperties.names(style: Types.ComputedStyle): ({ [string]: string }?, string?)
	for _, property in { "writing-mode", "direction" } do
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
	end
	local mode = word(style, "writing-mode", "horizontal-tb")
	local direction = word(style, "direction", "ltr")
	if not mode or not direction then
		return nil, "invalid-logical-writing-axes"
	end
	if mode ~= "horizontal-tb" and mode ~= "vertical-rl" and mode ~= "vertical-lr" then
		return nil, `unsupported-writing-mode:{mode}`
	end
	if direction ~= "ltr" and direction ~= "rtl" then
		return nil, `unsupported-direction:{direction}`
	end
	local key = mode .. "/" .. direction
	if mappings[key] then
		return mappings[key], nil
	end
	local horizontal = mode == "horizontal-tb"
	local blockStart = if horizontal then "top" elseif mode == "vertical-rl" then "right" else "left"
	local blockEnd = if horizontal then "bottom" elseif mode == "vertical-rl" then "left" else "right"
	local inlineStart = if horizontal
		then (if direction == "ltr" then "left" else "right")
		else (if direction == "ltr" then "top" else "bottom")
	local inlineEnd = if horizontal
		then (if direction == "ltr" then "right" else "left")
		else (if direction == "ltr" then "bottom" else "top")
	local sides: { [string]: string } = {
		["block-start"] = blockStart,
		["block-end"] = blockEnd,
		["inline-start"] = inlineStart,
		["inline-end"] = inlineEnd,
	}
	local names: { [string]: string } = {}
	-- Legacy aliases share the same candidate/rollback and inheritance lookup.
	names["font-stretch"] = "font-width"
	names["word-wrap"] = "overflow-wrap"
	for logical, physical in sides do
		for _, family in { "padding", "margin", "scroll-padding", "scroll-margin" } do
			names[family .. "-" .. logical] = family .. "-" .. physical
		end
		names["inset-" .. logical] = physical
		for _, suffix in { "width", "style", "color" } do
			names["border-" .. logical .. "-" .. suffix] = "border-" .. physical .. "-" .. suffix
		end
	end
	for _, prefix in { "", "min-", "max-" } do
		names[prefix .. "inline-size"] = prefix .. (if horizontal then "width" else "height")
		names[prefix .. "block-size"] = prefix .. (if horizontal then "height" else "width")
	end
	names["overflow-inline"] = if horizontal then "overflow-x" else "overflow-y"
	names["overflow-block"] = if horizontal then "overflow-y" else "overflow-x"
	for _, block in { "start", "end" } do
		for _, inline in { "start", "end" } do
			local a = if block == "start" then blockStart else blockEnd
			local b = if inline == "start" then inlineStart else inlineEnd
			local verticalSide = if a == "top" or a == "bottom" then a else b
			local horizontalSide = if a == "left" or a == "right" then a else b
			names[`border-{block}-{inline}-radius`] = `border-{verticalSide}-{horizontalSide}-radius`
		end
	end
	table.freeze(names)
	mappings[key] = names
	return names, nil
end

local function resolve(
	style: Types.ComputedStyle,
	owned: boolean
): (Types.ComputedStyle?, string?, { [string]: string }?)
	local names, failure = LogicalProperties.names(style)
	if not names then
		return nil, failure, nil
	end
	local physicalOnly = true
	for logical in names do
		if style.properties[logical] ~= nil or style.priorities[logical] ~= nil then
			physicalOnly = false
			break
		end
	end
	if physicalOnly then
		-- Read-only consumers can use an already canonical style directly. An
		-- unanchored failure still requires filtering, even without aliases.
		local canonical = not owned
		for property in style.unresolved do
			if style.properties[property] == nil and style.priorities[property] == nil then
				canonical = false
				break
			end
		end
		if canonical then
			return style, nil, names
		end
		local unresolved: { [string]: string } = {}
		for property, reason in style.unresolved do
			if style.properties[property] ~= nil or style.priorities[property] ~= nil then
				unresolved[property] = reason
			end
		end
		return {
			properties = table.clone(style.properties),
			variables = style.variables,
			unresolvedVariables = style.unresolvedVariables,
			priorities = table.clone(style.priorities),
			unresolved = unresolved,
		},
			nil,
			names
	end
	local result: Types.ComputedStyle = {
		properties = {},
		variables = style.variables,
		unresolvedVariables = style.unresolvedVariables,
		priorities = {},
		unresolved = {},
	}
	local visited: { [string]: boolean } = {}
	local function assign(property: string)
		if visited[property] then
			return
		end
		visited[property] = true
		local target = names[property] or property
		local priority = style.priorities[property]
		local previous = result.priorities[target]
		if not previous or (priority and Cascade.outranks(priority, previous)) then
			result.properties[target] = style.properties[property]
			result.priorities[target] = priority
			result.unresolved[target] = style.unresolved[property]
		end
	end
	for property in style.properties do
		assign(property)
	end
	for property in style.priorities do
		assign(property)
	end
	return result, nil, names
end

-- Ordinary resolution owns fresh property/priority/failure maps. The view is
-- for read-only formatting; callers clone it before editing. Neither path
-- retains caller identities, so mutable external requests stay observable.
function LogicalProperties.resolve(style: Types.ComputedStyle): (Types.ComputedStyle?, string?, { [string]: string }?)
	return resolve(style, true)
end

function LogicalProperties.view(style: Types.ComputedStyle): (Types.ComputedStyle?, string?, { [string]: string }?)
	return resolve(style, false)
end

function LogicalProperties.lookup(
	style: Types.ComputedStyle,
	property: string
): ({ Types.ValueToken }?, string?, string?)
	local resolved, failure, names = LogicalProperties.view(style)
	if not resolved or not names then
		return nil, failure, nil
	end
	local target = names[property] or property
	return resolved.properties[target], nil, resolved.unresolved[target]
end

-- One immutable parent can supply many inherited longhands. Resolve its
-- physical/logical candidate conflicts once for the current value calculation.
function LogicalProperties.createLookup(style: Types.ComputedStyle): Lookup
	local resolved, failure, names = LogicalProperties.resolve(style)
	if not resolved or not names then
		return function(_property: string): ({ Types.ValueToken }?, string?, string?)
			return nil, failure, nil
		end
	end
	local properties, unresolved = resolved.properties, resolved.unresolved
	local aliases: { [string]: string } = names
	return function(property: string): ({ Types.ValueToken }?, string?, string?)
		local target = aliases[property] or property
		return properties[target], nil, unresolved[target]
	end
end

return LogicalProperties
