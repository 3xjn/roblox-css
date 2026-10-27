--!strict

local Types = require(script.Parent.Types)
local Shorthands = require(script.Parent.Shorthands)
local LogicalProperties = require(script.Parent.LogicalProperties)
local RegisteredValues = require(script.Parent.RegisteredValues)
type Token = Types.ValueToken

local Variables = {}

export type Defaults = {
	values: { [string]: { Token } },
	pending: { [string]: string },
	propertyMetadata: { [string]: Types.PropertyMetadata }?,
	initialProperties: { [string]: { Token } }?,
}
export type ParentReads = {
	properties: { [string]: boolean },
	lookups: { [string]: boolean },
	-- Explicit inheritance can read even an inherits:false registration.
	variables: { [string]: boolean }?,
}
type ValueEntry = {
	declaration: Types.Declaration,
	dependencies: { [string]: boolean },
	values: { [string]: { Token } },
	pending: { [string]: string },
	tokens: { Token },
}
export type ValueCache = { entries: { [string]: ValueEntry } }

-- Registered initial values are independent of the node and its environment.
-- Keep this snapshot with its prepared stylesheet, not in a process-wide cache.
function Variables.prepareDefaults(registrations: { [string]: Types.Registration }): Defaults
	local result: Defaults = { values = {}, pending = {} }
	for name, registration in registrations do
		if registration.initial then
			local value, failure = RegisteredValues.compute(registration.initial, registration)
			result.values[name] = value or registration.initial
			result.pending[name] = failure or (if not value then "registered-initial-value-invalid" else nil)
		end
	end
	return result
end

-- Prepared stylesheet metadata is immutable within its owning root/context.
-- Reuse registration defaults and own one initial-property template. Each
-- computation still receives a fresh property map; direct calls omit this.
function Variables.prepareProperties(defaults: Defaults, metadata: { [string]: Types.PropertyMetadata }): Defaults
	local initial: { [string]: { Token } } = {}
	for property, info in metadata do
		if info.inherited and info.initial then
			initial[property] = info.initial
		end
	end
	return {
		values = defaults.values,
		pending = defaults.pending,
		propertyMetadata = metadata,
		initialProperties = table.freeze(initial),
	}
end

local fallbackInherited: { [string]: boolean } = {
	direction = true,
	["writing-mode"] = true,
	color = true,
	["font-family"] = true,
	["font-size"] = true,
	["font-style"] = true,
	["font-weight"] = true,
	["font-feature-settings"] = true,
	["font-variation-settings"] = true,
	["font-variant-numeric"] = true,
	["letter-spacing"] = true,
	["line-height"] = true,
	["text-align"] = true,
	["text-indent"] = true,
	["text-transform"] = true,
	["white-space"] = true,
	["white-space-collapse"] = true,
	["text-wrap-mode"] = true,
	["text-wrap-style"] = true,
	["tab-size"] = true,
	["overflow-wrap"] = true,
	["visibility"] = true,
	cursor = true,
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

local function keyword(tokens: { Token }): string?
	local value: string? = nil
	for _, token in tokens do
		if token.kind == "space" or token.kind == "comment" then
			continue
		end
		if value or token.kind ~= "word" then
			return nil
		end
		value = string.lower(token.identifier or token.value)
	end
	return value
end

local function varArguments(tokens: { Token }): (string?, { Token }?)
	local first = {}
	local fallback: { Token }? = nil
	for _, token in tokens do
		if not fallback and token.kind == "div" and token.value == "," then
			fallback = {}
		elseif fallback then
			table.insert(fallback, token)
		else
			table.insert(first, token)
		end
	end
	local filtered = significant(first)
	if
		#filtered ~= 1
		or filtered[1].kind ~= "word"
		or filtered[1].value:sub(1, 2) ~= "--"
		or #filtered[1].value < 3
	then
		return nil, nil
	end
	return filtered[1].value, fallback
end

local function dependencies(tokens: { Token }, result: { [string]: boolean })
	for _, token in tokens do
		if token.children then
			if token.kind == "function" and string.lower(token.value) == "var" then
				local name = varArguments(token.children or {})
				if name then
					result[name] = true
				end
			end
			dependencies(token.children, result)
		end
	end
end

function Variables.compute(
	winners: { [string]: Types.Declaration },
	parent: Types.ComputedStyle?,
	registrations: { [string]: Types.Registration },
	diagnose: Types.Diagnose,
	metadata: { [string]: Types.PropertyMetadata }?,
	rollback: Types.Rollback?,
	defaults: Defaults?,
	parentReads: ParentReads?,
	baseVariables: Types.ComputedStyle?,
	valueCache: ValueCache?
): Types.ComputedStyle
	local prepared = defaults or Variables.prepareDefaults(registrations)
	local definitions: { [string]: Types.PropertyMetadata } = metadata or {}
	local initialProperties = if prepared.propertyMetadata == definitions then prepared.initialProperties else nil
	local result: Types.ComputedStyle = {
		properties = if initialProperties then table.clone(initialProperties) else {},
		variables = {},
		priorities = {},
		unresolved = {},
	}
	local pendingVariables: { [string]: string } = {}
	result.unresolvedVariables = pendingVariables
	local parentPending = if parent then parent.unresolvedVariables or {} else {}
	local initialValues, initialPending = prepared.values, prepared.pending
	local parentLookup: LogicalProperties.Lookup? = nil
	local function inherits(property: string): boolean
		local info = definitions[property]
		return if info then info.inherited else fallbackInherited[property] == true
	end
	local function initial(property: string): { Token }?
		local info = definitions[property]
		return if info then info.initial else nil
	end
	local parentVariables = if parent then parent.variables else {}
	-- Effect values resolve var() against the target's current computed custom
	-- properties, including registered properties which do not inherit.
	-- Do not copy parent/default variables only to discard them in this branch.
	if baseVariables then
		result.variables = table.clone(baseVariables.variables)
		for name, failure in baseVariables.unresolvedVariables or {} do
			pendingVariables[name] = failure
		end
	else
		for name, tokens in parentVariables do
			local registration = registrations[name]
			if not registration or registration.inherits then
				result.variables[name] = tokens
				pendingVariables[name] = parentPending[name]
			end
		end
		for name, registration in registrations do
			if result.variables[name] == nil and registration.initial then
				result.variables[name] = initialValues[name]
				pendingVariables[name] = initialPending[name]
			end
		end
	end
	local locals: { [string]: { Token } } = {}
	for property, declaration in winners do
		if property:sub(1, 2) == "--" then
			result.priorities[property] = declaration.priority
			local value = keyword(declaration.tokens)
			local registration = registrations[property]
			if value == "initial" then
				result.variables[property] = initialValues[property]
				pendingVariables[property] = initialPending[property]
			elseif value == "inherit" or (value == "unset" and (not registration or registration.inherits)) then
				if parentReads and parentReads.variables then
					parentReads.variables[property] = true
				end
				result.variables[property] = parentVariables[property] or initialValues[property]
				pendingVariables[property] = if parentVariables[property]
					then parentPending[property]
					else initialPending[property]
			elseif value == "unset" then
				result.variables[property] = initialValues[property]
				pendingVariables[property] = initialPending[property]
			elseif value == "revert" or value == "revert-layer" then
				diagnose("unsupported-cascade-keyword", `{property}: {value}`, declaration.source)
			else
				locals[property] = declaration.tokens
			end
		end
	end

	-- Cycles include references in var() fallbacks. Detect the graph before resolving.
	local graph: { [string]: { [string]: boolean } } = {}
	for name, tokens in locals do
		local refs = {}
		dependencies(tokens, refs)
		graph[name] = refs
	end
	local active: { [string]: number } = {}
	local visited: { [string]: boolean } = {}
	local invalid: { [string]: boolean } = {}
	local path: { string } = {}
	local function detect(name: string)
		local index = active[name]
		if index then
			for position = index, #path do
				invalid[path[position]] = true
			end
			return
		end
		if visited[name] or not graph[name] then
			return
		end
		table.insert(path, name)
		active[name] = #path
		for dependency in graph[name] do
			detect(dependency)
		end
		active[name] = nil
		table.remove(path)
		visited[name] = true
	end
	for name in locals do
		detect(name)
	end

	local resolved: { [string]: boolean } = {}
	local restartName: string? = nil
	local restartDeclaration: Types.Declaration? = nil
	local resolveVariable: (string) -> { Token }?
	local substitute: ({ Token }) -> ({ Token }?, string?)

	substitute = function(tokens: { Token }): ({ Token }?, string?)
		local output: { Token }? = nil
		for index, token in tokens do
			local part = token
			if token.kind == "function" and string.lower(token.value) == "var" then
				local name, fallback = varArguments(token.children or {})
				if not name then
					return nil, nil
				end
				local replacement = resolveVariable(name)
				if pendingVariables[name] then
					return tokens, pendingVariables[name]
				end
				if not replacement and fallback then
					local failure: string?
					replacement, failure = substitute(fallback)
					if failure then
						return tokens, failure
					end
				end
				if not replacement then
					return nil, nil
				end
				if not output then
					output = {}
					for position = 1, index - 1 do
						output[position] = tokens[position]
					end
				end
				for _, replacementPart in replacement do
					table.insert(output, replacementPart)
				end
				continue
			elseif token.children then
				local children, failure = substitute(token.children)
				if failure then
					return tokens, failure
				end
				if not children then
					return nil, nil
				end
				if children ~= token.children then
					part = table.clone(token)
					part.children = children
				end
			end
			if part ~= token and not output then
				output = {}
				for position = 1, index - 1 do
					output[position] = tokens[position]
				end
			end
			if output then
				table.insert(output, part)
			end
		end
		return output or tokens, nil
	end

	resolveVariable = function(name: string): { Token }?
		if resolved[name] or not locals[name] then
			return result.variables[name]
		end
		resolved[name] = true
		local value: { Token }? = nil
		local failure: string? = nil
		if not invalid[name] then
			value, failure = substitute(locals[name])
		end
		local registration = registrations[name]
		if restartName then
			return nil
		end
		local wide = if value and not failure then keyword(value) else nil
		if wide == "initial" or (wide == "unset" and registration and not registration.inherits) then
			value = initialValues[name]
			failure = initialPending[name]
		elseif wide == "inherit" or wide == "unset" then
			if parentReads and parentReads.variables then
				parentReads.variables[name] = true
			end
			value = parentVariables[name] or initialValues[name]
			failure = if parentVariables[name] then parentPending[name] else initialPending[name]
		elseif wide == "revert" or wide == "revert-layer" then
			if rollback then
				restartName = name
				restartDeclaration = rollback(name, winners[name], wide)
				return nil
			end
			diagnose("unsupported-cascade-keyword", `{name}: {wide}`, winners[name].source)
			value = nil
		end
		if value and registration and not wide and not failure then
			local computed, pending = RegisteredValues.compute(value, registration)
			if not computed and not pending then
				diagnose("invalid-registered-value", name, winners[name].source)
			end
			value = if pending then value else computed
			failure = pending
		end
		if
			not value
			and registration
			and registration.syntaxDefinition
			and not registration.syntaxDefinition.universal
		then
			value = if registration.inherits then parentVariables[name] or initialValues[name] else initialValues[name]
			failure = if registration.inherits and parentVariables[name]
				then parentPending[name]
				else initialPending[name]
		end
		result.variables[name] = value
		pendingVariables[name] = failure
		if failure then
			diagnose("custom-property-computation-pending", `{name}: {failure}`, winners[name].source)
		end
		return result.variables[name]
	end
	for name in locals do
		resolveVariable(name)
		if restartName then
			break
		end
	end
	if restartName then
		-- Rebuild dependencies after changing one custom-property declaration.
		-- Each rollback moves below its normal layer boundary or removes the
		-- author's value; this is a finite cascade calculation, not a retry timer.
		local nextWinners = table.clone(winners)
		nextWinners[restartName] = restartDeclaration
		return Variables.compute(
			nextWinners,
			parent,
			registrations,
			diagnose,
			metadata,
			rollback,
			prepared,
			parentReads,
			baseVariables,
			valueCache
		)
	end
	for name in locals do
		if invalid[name] then
			diagnose("cyclic-variable", name, winners[name].source)
		end
	end

	if not initialProperties then
		for property, info in definitions do
			if info.inherited and info.initial then
				result.properties[property] = info.initial
			end
		end
	end
	if parent then
		for property, tokens in parent.properties do
			local info = definitions[property]
			if if info then info.inherited else fallbackInherited[property] == true then
				if parentReads then
					parentReads.properties[property] = true
				end
				result.properties[property] = tokens
				result.unresolved[property] = parent.unresolved[property]
			end
		end
	end
	local nextValues: { [string]: ValueEntry }? = if valueCache then {} else nil
	for property, original in winners do
		if property:sub(1, 2) ~= "--" then
			-- Only immutable prepared selections qualify. The value proof covers
			-- every var() reference, including unused fallbacks. Inheritance,
			-- rollback and diagnostics still take the ordinary path below.
			local retained = if valueCache and table.isfrozen(original) then valueCache.entries[property] else nil
			if retained and retained.declaration == original then
				local same = true
				for name in retained.dependencies do
					if
						retained.values[name] ~= result.variables[name]
						or retained.pending[name] ~= pendingVariables[name]
					then
						same = false
						break
					end
				end
				if same then
					result.properties[property] = retained.tokens
					result.priorities[property] = original.priority
					result.unresolved[property] = nil
					assert(nextValues)[property] = retained
					continue
				end
			end
			local declaration = original
			while true do
				if declaration.priority then
					result.priorities[property] = declaration.priority
				end
				local tokens, substitutionFailure = substitute(declaration.tokens)
				if substitutionFailure then
					result.properties[property] = tokens or declaration.tokens
					result.unresolved[property] = substitutionFailure
					diagnose("variable-computation-pending", `{property}: {substitutionFailure}`, declaration.source)
					break
				end
				if tokens and declaration.shorthand then
					local expanded, failure, pending =
						Shorthands.resolve(declaration.shorthand.property, declaration.shorthand.target, tokens)
					if failure then
						if pending then
							diagnose(
								"unresolved-shorthand",
								`{declaration.shorthand.property}: {failure}`,
								declaration.source
							)
							result.properties[property] = tokens
							result.unresolved[property] = failure
						else
							diagnose(
								"invalid-shorthand",
								`{declaration.shorthand.property}: {failure}`,
								declaration.source
							)
							if not inherits(property) then
								result.properties[property] = initial(property)
								result.unresolved[property] = nil
							end
						end
						break
					end
					tokens = expanded
				end
				if not tokens then
					-- A missing or cyclic custom property invalidates this declaration at
					-- computed-value time. CSS uses the inherited or initial value; it
					-- is not a syntax error and may resolve on a subsequent layout.
					if not inherits(property) then
						result.properties[property] = initial(property)
						result.unresolved[property] = nil
					end
					break
				end
				local value = keyword(tokens)
				result.unresolved[property] = nil
				if value == "inherit" or (value == "unset" and inherits(property)) then
					if parent then
						if parentReads then
							parentReads.lookups[declaration.property] = true
						end
						local lookup = parentLookup or LogicalProperties.createLookup(parent)
						parentLookup = lookup
						local inheritedValue, failure, unresolved = lookup(declaration.property)
						if failure then
							diagnose("inheritance-mapping-pending", failure, declaration.source)
						end
						result.properties[property] = inheritedValue
						result.unresolved[property] = unresolved
					else
						result.properties[property] = initial(property)
					end
				elseif value == "initial" or value == "unset" then
					result.properties[property] = initial(property)
				elseif value == "revert" or value == "revert-layer" then
					if not rollback then
						result.unresolved[property] = "cascade-rollback-provider-required"
						diagnose("unsupported-cascade-keyword", `{property}: {value}`, declaration.source)
						break
					end
					local previous = rollback(property, declaration, value)
					if not previous then
						result.priorities[property] = nil
						break
					end
					declaration = previous
					continue
				else
					result.properties[property] = tokens
					if
						nextValues
						and declaration == original
						and table.isfrozen(original)
						and (
							original.shorthand ~= nil
							or #original.tokens > 1
							or original.tokens[1] and original.tokens[1].children ~= nil
						)
					then
						local refs: { [string]: boolean } = {}
						dependencies(original.tokens, refs)
						local values, pending = {}, {}
						for name in refs do
							values[name], pending[name] = result.variables[name], pendingVariables[name]
						end
						nextValues[property] = {
							declaration = original,
							dependencies = refs,
							values = values,
							pending = pending,
							tokens = tokens,
						}
					end
				end
				break
			end
		end
	end
	if valueCache then
		valueCache.entries = assert(nextValues)
	end
	return result
end

return Variables
