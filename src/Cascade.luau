--!strict

local Types = require(script.Parent.Types)
local Selectors = require(script.Parent.Selectors)
local Shorthands = require(script.Parent.Shorthands)
local SelectorIndex = require(script.Parent.SelectorIndex)
local Keyframes = require(script.Parent.Keyframes)

type Layer = { order: { string }, children: { [string]: Layer } }
type Winner = Types.CascadeCandidate
-- Root-private selections share immutable prepared candidates. Weak keys let
-- replaced inline candidates retire without extending their source lifetime.
-- Omit this cache when callers need independently mutable declarations.
export type SelectionCache = { [Winner]: Types.Declaration }

local Cascade = {}

local function layerPath(root: Layer, names: { string }): { number }
	local result = {}
	local current = root
	for _, name in names do
		local child = current.children[name]
		if not child then
			child = { order = {}, children = {} }
			current.children[name] = child
			table.insert(current.order, name)
		end
		table.insert(result, table.find(current.order, name) :: number)
		current = child
	end
	return result
end

local function appendNames(parent: { string }, name: string): { string }
	local result = table.clone(parent)
	for part in name:gmatch("[^.]+") do
		table.insert(result, part:match("^%s*(.-)%s*$") or part)
	end
	return result
end

function Cascade.prepare(sheet: Types.Stylesheet, diagnose: Types.Diagnose): Types.PreparedSheet
	assert(sheet.version == 1, "Unsupported CSS stylesheet version")
	local result: Types.PreparedSheet = { rules = {}, registrations = {}, properties = sheet.properties or {} }
	local pseudoElements: { [string]: boolean } = {}
	result.pseudoElements = pseudoElements
	local layers: Layer = { order = {}, children = {} }
	local anonymous = 0
	local declarationOrder = 0
	local function visit(nodes: { Types.CssNode }, names: { string }, conditions: { Types.Condition })
		for _, node in nodes do
			if node.kind == "rule" then
				local selectors = {}
				for _, selector in node.selectors do
					local tokens, target, failure = Selectors.splitTarget(selector.tokens)
					if target == "unavailable" then
						continue
					end
					if tokens then
						failure = Selectors.validate(tokens)
					end
					if failure then
						diagnose("unsupported-selector", `{selector.text}: {failure}`, node.source)
					else
						local prepared = table.clone(selector)
						prepared.tokens = tokens or selector.tokens
						prepared.pseudoElement = target
						if target then
							pseudoElements[target] = true
						end
						table.insert(selectors, prepared)
					end
				end
				local declarations = {}
				for _, child in node.children do
					if child.kind == "declaration" then
						declarationOrder += 1
						if
							child.property == "all" and not (result.properties.all and result.properties.all.longhands)
						then
							diagnose("unsupported-shorthand", "all requires compiled longhand metadata", child.source)
							continue
						end
						if child.validity == "invalid" then
							diagnose("invalid-declaration", `{child.property}: {child.value}`, child.source)
						else
							for _, expanded in Shorthands.expand(child, result.properties) do
								local prepared = table.clone(expanded)
								prepared.cascadeOrder = declarationOrder
								table.insert(declarations, prepared)
							end
						end
					else
						diagnose("nested-runtime-rule", "Nested CSS must be normalized by the compiler", child.source)
					end
				end
				table.insert(result.rules, {
					selectors = selectors,
					declarations = declarations,
					layer = layerPath(layers, names),
					conditions = conditions,
					candidates = {},
				})
			elseif node.kind == "at-rule" then
				if node.name == "layer" then
					if node.children then
						local name = node.params
						if name == "" then
							anonymous += 1
							name = `#anonymous-{anonymous}`
						end
						local nextNames = appendNames(names, name)
						layerPath(layers, nextNames)
						visit(node.children, nextNames, conditions)
					else
						for name in node.params:gmatch("[^,]+") do
							layerPath(layers, appendNames(names, name))
						end
					end
				elseif node.name == "property" then
					local compiled = node.registration
					if not compiled then
						diagnose(
							"property-registration-metadata-required",
							`Regenerate @property {node.params}`,
							node.source
						)
						continue
					end
					if compiled.status == "invalid" then
						diagnose("invalid-property-registration", `{node.params}: {compiled.reason}`, node.source)
						continue
					end
					result.registrations[compiled.name] = {
						inherits = compiled.inherits,
						syntax = compiled.syntax,
						initial = compiled.initial,
						syntaxDefinition = compiled.syntaxDefinition,
					}
					if compiled.status == "unchecked" then
						diagnose(
							"property-registration-validation-pending",
							`{compiled.name}: {compiled.reason or "registered-value validation required"}`,
							node.source
						)
					end
				elseif node.name == "keyframes" or node.name == "-webkit-keyframes" then
					local definition =
						Keyframes.prepare(node, layerPath(layers, names), conditions, result.properties, diagnose)
					if definition then
						local definitions = result.keyframes or {}
						result.keyframes = definitions
						local named = definitions[definition.name] or {}
						definitions[definition.name] = named
						table.insert(named, definition)
					end
				elseif node.name == "media" or node.name == "supports" or node.name == "container" then
					local nextConditions = table.clone(conditions)
					table.insert(
						nextConditions,
						{ name = node.name, params = node.params, tokens = node.tokens, expression = node.condition }
					)
					visit(node.children or {}, names, nextConditions)
				else
					diagnose("unsupported-at-rule", `@{node.name} {node.params}`, node.source)
				end
			elseif node.kind == "declaration" then
				diagnose("unscoped-declaration", node.property, node.source)
			elseif node.kind == "keyframe-step" then
				diagnose("unscoped-keyframe", "Keyframe steps must belong to @keyframes", node.source)
			end
		end
	end
	visit(sheet.nodes, {}, {})
	result.selectorIndex = SelectorIndex.create(result.rules)
	return result
end

local function layerOrder(candidate: { number }, previous: { number }): number
	for index = 1, math.max(#candidate, #previous) do
		local a = candidate[index] or math.huge
		local b = previous[index] or math.huge
		if a ~= b then
			return if a < b then -1 else 1
		end
	end
	return 0
end

function Cascade.getKeyframes(
	sheet: Types.PreparedSheet,
	name: string,
	node: Types.Node,
	matchCondition: Types.MatchCondition
): (Types.PreparedKeyframes?, string?)
	local definitions = sheet.keyframes and sheet.keyframes[name]
	if not definitions then
		return nil, nil
	end
	local selected: Types.PreparedKeyframes? = nil
	local pending: Types.PreparedKeyframes? = nil
	local selectedIndex, pendingIndex = 0, 0
	for index, definition in definitions do
		local active: boolean? = true
		for _, condition in definition.conditions do
			local matched = matchCondition(condition, node)
			if matched == false then
				active = false
				break
			end
			if matched == nil then
				active = nil
			end
		end
		if active == true and (not selected or layerOrder(definition.layer, selected.layer) >= 0) then
			selected, selectedIndex = definition, index
		elseif active == nil and (not pending or layerOrder(definition.layer, pending.layer) >= 0) then
			pending, pendingIndex = definition, index
		end
	end
	if pending then
		-- At equal layer precedence, only a later unknown candidate can replace
		-- a known winner. Array order is the definition's source order.
		local order = if selected then layerOrder(pending.layer, selected.layer) else 1
		if order > 0 or (order == 0 and pendingIndex > selectedIndex) then
			return nil, "keyframes-condition-provider-required"
		end
	end
	return selected, nil
end

local function beats(candidate: Types.Priority, previous: Types.Priority): boolean
	local important = candidate.important
	if important ~= previous.important then
		return important
	end
	if (candidate.inline == true) ~= (previous.inline == true) then
		return candidate.inline == true
	end
	local layer = layerOrder(candidate.layer, previous.layer)
	if layer ~= 0 then
		return if important then layer < 0 else layer > 0
	end
	for index = 1, 3 do
		local a = candidate.specificity[index]
		local b = previous.specificity[index]
		if a ~= b then
			return a > b
		end
	end
	if candidate.order ~= previous.order then
		return candidate.order > previous.order
	end
	-- One shorthand can set both aliases at the same source position. Physical
	-- longhands are ordered last (notably for all: inherit across directions).
	if (candidate.logical == true) ~= (previous.logical == true) then
		return candidate.logical ~= true
	end
	return true
end

local function rollbackKeyword(tokens: { Types.ValueToken }): string?
	local value: string? = nil
	for _, token in tokens do
		if token.kind == "space" or token.kind == "comment" then
			continue
		end
		if value or token.kind ~= "word" then
			return nil
		end
		value = string.lower(token.value)
	end
	return if value == "revert" or value == "revert-layer" then value else nil
end

local function finitePriority(priority: Types.Priority): boolean
	local order = priority.order
	if order ~= order or math.abs(order) == math.huge then
		return false
	end
	for _, values in { priority.layer, priority.specificity } do
		for _, value in values do
			if value ~= value or math.abs(value) == math.huge then
				return false
			end
		end
	end
	return true
end

local function freezeSelection(selection: Types.Declaration)
	table.freeze(assert(selection.priority))
	table.freeze(selection)
end

local function selectValue(
	candidates: { Winner },
	boundary: Types.Priority?,
	selections: SelectionCache?
): Types.Declaration?
	local ceiling = boundary
	while true do
		local best: Winner? = nil
		for _, candidate in candidates do
			-- A layer rollback removes the interval down through its NORMAL
			-- layer level, including intervening important declarations.
			if
				ceiling
				and (
					candidate.priority.inline == true
					or (
						ceiling.inline ~= true
						and (candidate.priority.important or layerOrder(candidate.priority.layer, ceiling.layer) >= 0)
					)
				)
			then
				continue
			end
			if not best or beats(candidate.priority, best.priority) then
				best = candidate
			end
		end
		if not best then
			return nil
		end
		local keyword = rollbackKeyword(best.declaration.tokens)
		if keyword == "revert" then
			-- This stylesheet model currently has a single author origin.
			return nil
		elseif keyword == "revert-layer" then
			ceiling = best.priority
		else
			local previous = if selections then selections[best] else nil
			if previous then
				return previous
			end
			local result: Types.Declaration = table.clone(best.declaration)
			-- Prepared candidates are immutable. Ordinary calls own a fresh
			-- declaration and priority; an opted-in root retains that snapshot.
			local priority = table.clone(best.priority)
			result.priority = priority
			if selections and finitePriority(best.priority) then
				freezeSelection(result)
				selections[best] = result
			end
			return result
		end
	end
end

local function selectCandidates(
	candidates: { [string]: { Winner } },
	selections: SelectionCache?
): ({ [string]: Types.Declaration }, Types.Rollback)
	local result: { [string]: Types.Declaration } = {}
	for property, values in candidates do
		local selected = selectValue(values, nil, selections)
		if selected then
			result[property] = selected
		end
	end
	local function rollback(property: string, declaration: Types.Declaration, keyword: string): Types.Declaration?
		if keyword == "revert" then
			return nil
		end
		if keyword ~= "revert-layer" or not declaration.priority then
			return nil
		end
		return selectValue(candidates[property] or {}, declaration.priority, selections)
	end
	return result, rollback
end

local function prepareCandidates(rule: Types.PreparedRule, specificity: { number }, offset: number): { Winner }
	local result: { Winner } = {}
	local base: Types.Priority? = nil
	local physical: Types.Priority? = nil
	local logical: Types.Priority? = nil
	for index, declaration in rule.declarations do
		local order = declaration.cascadeOrder or offset + index
		if not base or base.order ~= order or base.important ~= declaration.important then
			local priority: Types.Priority = {
				important = declaration.important,
				layer = rule.layer,
				specificity = specificity,
				order = order,
			}
			base = priority
			local physicalPriority = table.clone(priority)
			physicalPriority.logical = false
			physical = physicalPriority
			local logicalPriority = table.clone(priority)
			logicalPriority.logical = true
			logical = logicalPriority
		end
		local physicalCandidate: Winner = { declaration = declaration, priority = assert(physical) }
		local logicalCandidate: Winner = { declaration = declaration, priority = assert(logical) }
		local candidate: Winner = {
			declaration = declaration,
			priority = assert(base),
			physical = physicalCandidate,
			logical = logicalCandidate,
		}
		result[index] = candidate
	end
	return table.freeze(result)
end

-- Predicate reordering requires a read-only dependency observer. Direct calls
-- preserve their existing observation order unless they explicitly opt in.
function Cascade.compute(
	sheet: Types.PreparedSheet,
	node: Types.Node,
	matchCondition: Types.MatchCondition,
	diagnose: Types.Diagnose,
	pseudoElement: string?,
	observe: Selectors.Observer?,
	selections: SelectionCache?,
	anchorsFirst: boolean?
): ({ [string]: Types.Declaration }, Types.Rollback, Types.RemapCascade)
	local candidates: { [string]: { Winner } } = {}
	local matches = if anchorsFirst then Selectors.matchesPrepared else Selectors.matches
	local scope = node
	while scope.parent do
		scope = scope.parent
	end
	local order = 0
	local selectorIndex = sheet.selectorIndex
	local indices: { number } = {}
	if selectorIndex then
		indices = SelectorIndex.candidates(selectorIndex, node, pseudoElement)
	else
		for index in sheet.rules do
			table.insert(indices, index)
		end
	end
	for _, index in indices do
		local rule = sheet.rules[index]
		if selectorIndex then
			order = selectorIndex.declarationOffsets[index]
		end
		local enabled = true
		for _, condition in rule.conditions do
			local matched = matchCondition(condition, node)
			if matched == nil then
				diagnose("unsupported-condition", `@{condition.name} {condition.params}`, nil)
			end
			if matched ~= true then
				enabled = false
				break
			end
		end
		local specificity: { number }? = nil
		if enabled then
			for _, selector in rule.selectors do
				if selector.pseudoElement == pseudoElement and matches(selector.tokens, node, scope, observe) then
					local current = specificity
					if not current then
						specificity = selector.specificity
					else
						for index = 1, 3 do
							if selector.specificity[index] > current[index] then
								specificity = selector.specificity
								break
							elseif selector.specificity[index] < current[index] then
								break
							end
						end
					end
				end
			end
		end
		local prepared = if specificity and rule.candidates then rule.candidates[specificity] else nil
		if specificity and rule.candidates and not prepared then
			prepared = prepareCandidates(rule, specificity, order)
			rule.candidates[specificity] = prepared
		end
		for declarationIndex, declaration in rule.declarations do
			order += 1
			if specificity then
				local candidate: Winner = if prepared
					then prepared[declarationIndex]
					else {
						declaration = declaration,
						priority = {
							important = declaration.important,
							layer = rule.layer,
							specificity = specificity,
							order = declaration.cascadeOrder or order,
						},
					}
				local values = candidates[declaration.property]
				if not values then
					values = {}
					candidates[declaration.property] = values
				end
				table.insert(values, candidate)
			end
		end
	end
	if pseudoElement == nil and node.inlineCandidates then
		for _, candidate in node.inlineCandidates do
			local property = candidate.declaration.property
			local values = candidates[property] or {}
			candidates[property] = values
			table.insert(values, candidate)
		end
	end
	local lastNames: { [string]: string }? = nil
	local lastWinners: { [string]: Types.Declaration }? = nil
	local lastRollback: Types.Rollback? = nil
	local function remap(names: { [string]: string }): ({ [string]: Types.Declaration }, Types.Rollback)
		if names == lastNames and lastWinners and lastRollback then
			return lastWinners, lastRollback
		end
		local mapped: { [string]: { Winner } } = {}
		for property, values in candidates do
			local target = names[property] or property
			local group = mapped[target]
			if not group then
				group = {}
				mapped[target] = group
			end
			for _, candidate in values do
				local prepared = if target ~= property then candidate.logical else candidate.physical
				if prepared then
					table.insert(group, prepared)
				else
					local priority = table.clone(candidate.priority)
					priority.logical = target ~= property
					table.insert(group, { declaration = candidate.declaration, priority = priority })
				end
			end
		end
		local winners, rollback = selectCandidates(mapped, selections)
		-- Root-private selections and frozen axis mappings are immutable.
		-- Ordinary mutable callers retain independent declaration maps.
		if selections and table.isfrozen(names) then
			local eligible = true
			for _, declaration in winners do
				if not table.isfrozen(declaration) then
					eligible = false
					break
				end
			end
			if eligible then
				table.freeze(winners)
				lastNames, lastWinners, lastRollback = names, winners, rollback
			end
		end
		return winners, rollback
	end
	local result, rollback = selectCandidates(candidates, selections)
	return result, rollback, remap
end

Cascade.outranks = beats

function Cascade.prepareInline(
	declarations: { Types.Declaration },
	metadata: { [string]: Types.PropertyMetadata },
	diagnose: Types.Diagnose
): { Winner }
	local expanded: { Types.Declaration } = {}
	for index, declaration in declarations do
		if declaration.validity == "invalid" then
			diagnose("invalid-declaration", `{declaration.property}: {declaration.value}`, declaration.source)
		elseif declaration.property == "all" and not (metadata.all and metadata.all.longhands) then
			diagnose("unsupported-shorthand", "all requires compiled longhand metadata", declaration.source)
		else
			for _, value in Shorthands.expand(declaration, metadata) do
				local copy = table.clone(value)
				copy.cascadeOrder = index
				table.insert(expanded, copy)
			end
		end
	end
	local candidates = prepareCandidates(
		{ selectors = {}, declarations = expanded, layer = {}, conditions = {} },
		{ 0, 0, 0 },
		0
	)
	for _, candidate in candidates do
		candidate.priority.inline = true
		if candidate.physical then
			candidate.physical.priority.inline = true
		end
		if candidate.logical then
			candidate.logical.priority.inline = true
		end
	end
	return candidates
end
return Cascade
