--!strict

local Types = require(script.Parent.Types)
local TextSegments = require(script.Parent.TextSegments)
local Cascade = require(script.Parent.Cascade)
local Variables = require(script.Parent.Variables)
local Conditions = require(script.Parent.Conditions)
local Keyframes = require(script.Parent.Keyframes)
local AnimationTracks = require(script.Parent.AnimationTracks)
local Easing = require(script.Parent.Easing)
local Typography = require(script.Parent.Typography)
local Fonts = require(script.Parent.Fonts)
local LogicalProperties = require(script.Parent.LogicalProperties)
local Profiler = require(script.Parent.Profiler)
local StateInvalidation = require(script.Parent.StateInvalidation)
local InlineStyle = require(script.Parent.InlineStyle)
local WorkQueue = require(script.Parent.WorkQueue)

export type Stylesheet = Types.Stylesheet
export type Node = Types.Node
export type ComputedStyle = Types.ComputedStyle

export type NodeOptions = {
	tag: string?,
	-- Native representation only; logical tag, selectors and layout stay intact.
	nativeControl: ("auto" | "button")?,
	id: string?,
	className: string?,
	attributes: { [string]: string }?,
	states: { [string]: boolean }?,
	text: string?,
	textAfter: TextSegments.After?,
	inlineStyle: Types.InlineStyle?,
}

export type RootOptions = {
	onProfile: Profiler.Sink?,
	onDiagnostic: Types.Diagnose?,
	matchCondition: Types.MatchCondition?,
	onStyle: ((Node, ComputedStyle) -> ())?,
	environment: Conditions.Environment?,
	supportsDeclaration: Conditions.SupportsDeclaration?,
	fontMetrics: Typography.MetricsProvider?,
	fonts: Fonts.Provider?,
	initialFontMetrics: Typography.Metrics?,
	fontSizeKeywords: { [string]: number }?,
	-- Host-language defaults for otherwise unspecified element display roles.
	displayDefaults: { [string]: string }?,
}

type CascadeResult = {
	inputs: { [Node]: number }?,
	localInputs: boolean?,
	localValues: { [string]: boolean | string }?,
	inlineCandidates: { Types.CascadeCandidate }?,
	scope: Node?,
	tag: string?,
	id: string?,
	className: string?,
	states: { [string]: boolean },
	parentReads: Variables.ParentReads?,
	winners: { [string]: Types.Declaration },
	rollback: Types.Rollback,
	remap: Types.RemapCascade,
	parent: ComputedStyle?,
	rootFontSize: number?,
	rootLineHeight: number?,
	parentMetrics: Typography.Metrics?,
	computed: ComputedStyle?,
	metrics: Typography.Metrics?,
	values: Variables.ValueCache?,
}

local function localInput(node: Node, name: string): (boolean | string)?
	if name:sub(1, 1) ~= "@" then
		return node.states[name] == true
	end
	local attribute = name:sub(2)
	return if attribute == "class"
		then node.className
		elseif attribute == "id" then node.id
		else node.attributes[attribute]
end

local function localValues(node: Node, dependencies: { [string]: boolean }): { [string]: boolean | string }
	local values: { [string]: boolean | string } = {}
	for name in dependencies do
		values[name] = localInput(node, name)
	end
	return values
end

local function sameLocalInputs(cached: CascadeResult, node: Node): boolean
	if
		not cached.localValues
		or cached.tag ~= node.tag
		or cached.id ~= node.id
		or cached.className ~= node.className
		or cached.inlineCandidates ~= node.inlineCandidates
	then
		return false
	end
	for name in cached.states do
		if cached.localValues[name] ~= localInput(node, name) then
			return false
		end
	end
	return true
end

local function sameMetrics(a: Typography.Metrics?, b: Typography.Metrics?): boolean
	if a == b then
		return true
	end
	if not a or not b then
		return false
	end
	for name, value in a do
		if b[name] ~= value then
			return false
		end
	end
	for name in b do
		if a[name] == nil then
			return false
		end
	end
	return true
end

local StyleRoot = {}
StyleRoot.__index = StyleRoot

local function canScopeInputs(options: RootOptions): boolean
	return not options.matchCondition
		and not options.supportsDeclaration
		and not options.fontMetrics
		and not options.fontSizeKeywords
		and not options.initialFontMetrics
end

local function propertyDefaults(self: Root, metadata: { [string]: Types.PropertyMetadata }): Variables.Defaults
	if not canScopeInputs(self._options) then
		return self._variableDefaults
	end
	local prepared = self._propertyDefaults[metadata]
	if not prepared then
		prepared = Variables.prepareProperties(self._variableDefaults, metadata)
		self._propertyDefaults[metadata] = prepared
	end
	return prepared
end

local function copyEnvironment(environment: Conditions.Environment?): Conditions.Environment
	local source: Conditions.Environment = environment or {}
	local result = table.clone(source)
	if result.features then
		result.features = table.clone(result.features)
	end
	return result
end

local function classSet(className: string): { [string]: boolean }
	local result = {}
	for name in className:gmatch("[^\t\n\f\r ]+") do
		result[name] = true
	end
	return result
end

local function sameTokens(a: { Types.ValueToken }, b: { Types.ValueToken }): boolean
	-- Computed token graphs are immutable; shared values need no deep walk.
	if a == b then
		return true
	end
	if #a ~= #b then
		return false
	end
	for index, token in a do
		local other = b[index]
		if
			token.kind ~= other.kind
			or token.value ~= other.value
			or token.quote ~= other.quote
			or token.unit ~= other.unit
		then
			return false
		end
		local color, otherColor = token.color, other.color
		if color and otherColor then
			if
				color.r ~= otherColor.r
				or color.g ~= otherColor.g
				or color.b ~= otherColor.b
				or color.alpha ~= otherColor.alpha
			then
				return false
			end
		elseif color ~= otherColor then
			return false
		end
		if token.children and other.children then
			if not sameTokens(token.children, other.children) then
				return false
			end
		elseif token.children ~= other.children then
			return false
		end
	end
	return true
end

local function sameMap(a: { [string]: { Types.ValueToken } }, b: { [string]: { Types.ValueToken } }): boolean
	if a == b then
		return true
	end
	for key, value in a do
		if not b[key] or not sameTokens(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function samePriorities(a: { [string]: Types.Priority }, b: { [string]: Types.Priority }): boolean
	if a == b then
		return true
	end
	for property, priority in a do
		local other = b[property]
		if priority == other then
			continue
		end
		if
			not other
			or priority.important ~= other.important
			or (priority.inline == true) ~= (other.inline == true)
			or priority.order ~= other.order
			or (priority.logical == true) ~= (other.logical == true)
		then
			return false
		end
		for index = 1, math.max(#priority.layer, #other.layer) do
			if priority.layer[index] ~= other.layer[index] then
				return false
			end
		end
		for index = 1, 3 do
			if priority.specificity[index] ~= other.specificity[index] then
				return false
			end
		end
	end
	for property in b do
		if a[property] == nil then
			return false
		end
	end
	return true
end

local function sameUnresolved(a: { [string]: string }, b: { [string]: string }): boolean
	if a == b then
		return true
	end
	for property, failure in a do
		if b[property] ~= failure then
			return false
		end
	end
	for property in b do
		if a[property] == nil then
			return false
		end
	end
	return true
end

local function sameStyle(a: ComputedStyle?, b: ComputedStyle): boolean
	return a ~= nil
		and sameMap(a.properties, b.properties)
		and sameMap(a.variables, b.variables)
		and samePriorities(a.priorities, b.priorities)
		and sameUnresolved(a.unresolved, b.unresolved)
		and sameUnresolved(a.unresolvedVariables or {}, b.unresolvedVariables or {})
end

local parentTypography = {
	"font-size",
	"font-weight",
	"line-height",
	"letter-spacing",
	"word-spacing",
	"tab-size",
	"writing-mode",
	"direction",
}

local function sameParentProperty(a: ComputedStyle, b: ComputedStyle, property: string): boolean
	local left, right = a.properties[property], b.properties[property]
	return (left == right or (left ~= nil and right ~= nil and sameTokens(left, right)))
		and a.unresolved[property] == b.unresolved[property]
end

local function parentVariable(
	name: string,
	reads: { [string]: boolean },
	registrations: { [string]: Types.Registration }
): boolean
	local registration = registrations[name]
	return reads[name] == true or not registration or registration.inherits
end

local function sameParentVariables(
	a: ComputedStyle,
	b: ComputedStyle,
	reads: { [string]: boolean }?,
	registrations: { [string]: Types.Registration }
): boolean
	if not reads then
		return sameMap(a.variables, b.variables)
			and sameUnresolved(a.unresolvedVariables or {}, b.unresolvedVariables or {})
	end
	for name, tokens in a.variables do
		if parentVariable(name, reads, registrations) then
			local other = b.variables[name]
			if not other or not sameTokens(tokens, other) then
				return false
			end
		end
	end
	for name in b.variables do
		if a.variables[name] == nil and parentVariable(name, reads, registrations) then
			return false
		end
	end
	if a.unresolvedVariables then
		for name, failure in a.unresolvedVariables do
			if
				parentVariable(name, reads, registrations)
				and (not b.unresolvedVariables or b.unresolvedVariables[name] ~= failure)
			then
				return false
			end
		end
	end
	if b.unresolvedVariables then
		for name in b.unresolvedVariables do
			if
				(not a.unresolvedVariables or a.unresolvedVariables[name] == nil)
				and parentVariable(name, reads, registrations)
			then
				return false
			end
		end
	end
	return true
end

local function sameParentInputs(
	cached: CascadeResult,
	parent: ComputedStyle?,
	registrations: { [string]: Types.Registration }
): boolean
	local previous = cached.parent
	if previous == parent then
		return true
	end
	local reads = cached.parentReads
	if not previous or not parent or not reads then
		return false
	end
	if not sameParentVariables(previous, parent, reads.variables, registrations) then
		return false
	end
	-- A new inherited property may not have been read by the prior computation.
	-- Keep the ordinary path whenever either property's presence set changes.
	for property in previous.properties do
		if parent.properties[property] == nil then
			return false
		end
	end
	for property in parent.properties do
		if previous.properties[property] == nil then
			return false
		end
	end
	for property in reads.properties do
		if not sameParentProperty(previous, parent, property) then
			return false
		end
	end
	-- Typography also reads parent values for relative units and invalid-value
	-- inheritance, including fields absent from the ordinary inherited copy.
	for _, property in parentTypography do
		if not sameParentProperty(previous, parent, property) then
			return false
		end
	end
	if next(reads.lookups) then
		local a, b = LogicalProperties.createLookup(previous), LogicalProperties.createLookup(parent)
		for property in reads.lookups do
			local left, leftFailure, leftPending = a(property)
			local right, rightFailure, rightPending = b(property)
			if
				leftFailure ~= rightFailure
				or leftPending ~= rightPending
				or not (left == right or (left ~= nil and right ~= nil and sameTokens(left, right)))
			then
				return false
			end
		end
	end
	return true
end

local function copyStyle(style: ComputedStyle): ComputedStyle
	return {
		properties = table.clone(style.properties),
		variables = table.clone(style.variables),
		priorities = table.clone(style.priorities),
		unresolved = table.clone(style.unresolved),
		unresolvedVariables = if style.unresolvedVariables then table.clone(style.unresolvedVariables) else nil,
	}
end

-- When only unspecified inherited properties changed, their computed tokens
-- already belong to the parent. Keep the child's resolved declarations and
-- replace those inherited fields without redoing substitution or typography.
-- Changed variables, font inputs or parent lookups, and local winners for a
-- changed inherited field, retain the ordinary path. Old snapshots stay intact.
local function reinheritStyle(
	cached: CascadeResult,
	parent: ComputedStyle,
	metadata: { [string]: Types.PropertyMetadata },
	registrations: { [string]: Types.Registration }
): (ComputedStyle?, Variables.ParentReads?)
	local previous, computed, reads = cached.parent, cached.computed, cached.parentReads
	if
		not previous
		or not computed
		or not reads
		or not sameParentVariables(previous, parent, reads.variables, registrations)
	then
		return nil, nil
	end
	for _, property in parentTypography do
		if not sameParentProperty(previous, parent, property) then
			return nil, nil
		end
	end
	for _, property in { "font-family", "font-style" } do
		if not sameParentProperty(previous, parent, property) then
			return nil, nil
		end
	end
	if next(reads.lookups) then
		local a, b = LogicalProperties.createLookup(previous), LogicalProperties.createLookup(parent)
		for property in reads.lookups do
			local left, leftFailure, leftPending = a(property)
			local right, rightFailure, rightPending = b(property)
			if
				leftFailure ~= rightFailure
				or leftPending ~= rightPending
				or not (left == right or (left ~= nil and right ~= nil and sameTokens(left, right)))
			then
				return nil, nil
			end
		end
	end
	local result, nextReads = computed, reads
	local function inherit(property: string): boolean
		local info = metadata[property]
		if not reads.properties[property] and not (info and info.inherited) then
			return true
		end
		if cached.winners[property] or computed.priorities[property] then
			return false
		end
		local value = parent.properties[property] or (info and info.initial)
		local failure = if parent.properties[property] then parent.unresolved[property] else nil
		local before = computed.properties[property]
		if
			not (before == value or (before ~= nil and value ~= nil and sameTokens(before, value)))
			or computed.unresolved[property] ~= failure
		then
			if result == computed then
				result = table.clone(computed)
				result.properties, result.unresolved =
					table.clone(computed.properties), table.clone(computed.unresolved)
			end
			result.properties[property], result.unresolved[property] = value, failure
		end
		if parent.properties[property] and not reads.properties[property] then
			if nextReads == reads then
				nextReads = table.clone(reads)
				nextReads.properties = table.clone(reads.properties)
			end
			nextReads.properties[property] = true
		end
		return true
	end
	for property in previous.properties do
		if not sameParentProperty(previous, parent, property) and not inherit(property) then
			return nil, nil
		end
	end
	for property in parent.properties do
		if previous.properties[property] == nil and not inherit(property) then
			return nil, nil
		end
	end
	return result, nextReads
end

local function inheritedAxes(parent: ComputedStyle?, metadata: { [string]: Types.PropertyMetadata }): ComputedStyle
	local result: ComputedStyle = { properties = {}, variables = {}, priorities = {}, unresolved = {} }
	for _, property in { "writing-mode", "direction" } do
		local info = metadata[property]
		if not info or info.inherited then
			local tokens = if parent then parent.properties[property] else nil
			result.properties[property] = tokens or (if info then info.initial else nil)
			result.unresolved[property] = if parent and tokens then parent.unresolved[property] else nil
		end
	end
	return result
end

function StyleRoot.new(sheet: Stylesheet, options: RootOptions?, workQueue: WorkQueue.Queue?)
	local settings: RootOptions = options or {}
	local reported: { [string]: boolean } = {}
	local function diagnose(code: string, detail: string, source: Types.Source?)
		local key = code .. ":" .. detail
		if reported[key] then
			return
		end
		reported[key] = true
		if settings.onDiagnostic then
			settings.onDiagnostic(code, detail, source)
		else
			warn(`[roblox-css:{code}] {detail}`)
		end
	end
	local prepared = Cascade.prepare(sheet, diagnose)
	local displayDefaults: { [string]: { Types.ValueToken } } = {}
	for tag, value in settings.displayDefaults or {} do
		assert(
			type(tag) == "string" and type(value) == "string" and value:match("^[a-z-]+$"),
			"Display defaults require tag names and single CSS keywords"
		)
		displayDefaults[tag] = { { kind = "word", value = value } }
	end
	local wrappingMetadata = prepared.properties["word-wrap"]
	if wrappingMetadata then
		-- Older compiled sheets emitted inherited defaults for both names.
		-- They are one property: an alias's initial normal must not overwrite
		-- an inherited canonical value with no local declaration priority.
		prepared.properties = table.clone(prepared.properties)
		if not prepared.properties["overflow-wrap"] then
			prepared.properties["overflow-wrap"] = wrappingMetadata
		end
		prepared.properties["word-wrap"] = nil
	end
	local defaultNames = LogicalProperties.names({ properties = {}, variables = {}, priorities = {}, unresolved = {} })
	local hasLogical = false
	for _, rule in prepared.rules do
		for _, declaration in rule.declarations do
			if defaultNames and defaultNames[declaration.property] then
				hasLogical = true
				break
			end
		end
		if hasLogical then
			break
		end
	end
	local scopedStates, stateTargets = StateInvalidation.prepare(prepared)
	local self = setmetatable({
		_sheet = prepared,
		_variableDefaults = Variables.prepareDefaults(prepared.registrations),
		_propertyDefaults = {} :: { [{ [string]: Types.PropertyMetadata }]: Variables.Defaults },
		_hasLogical = hasLogical,
		_displayDefaults = displayDefaults,
		_logicalNames = defaultNames or ({} :: { [string]: string }),
		_logicalMetadata = {} :: { [{ [string]: string }]: { [string]: Types.PropertyMetadata } },
		_diagnose = diagnose,
		_options = settings,
		_environment = copyEnvironment(settings.environment),
		_nodes = {} :: { [Node]: boolean },
		_computed = {} :: { [Node]: ComputedStyle },
		_pseudos = {} :: { [Node]: { [string]: ComputedStyle } },
		_anonymousStyles = {} :: { [Node]: ComputedStyle },
		_roots = {} :: { Node },
		_listeners = {} :: { [(Node, ComputedStyle) -> ()]: boolean },
		_commitListeners = {} :: { [(number) -> ()]: boolean },
		_revision = 0,
		_committedRevision = -1,
		_pending = false,
		_pendingUpdate = nil :: (() -> ())?,
		_updating = false,
		_workQueue = workQueue,
		_destroyed = false,
		_fontSubscription = nil :: (() -> ())?,
		_fontsChanged = false,
		_fullInvalidation = true,
		_inputInvalidation = false,
		_dirtyNodes = {} :: { [Node]: boolean },
		_changedStates = {} :: { [string]: boolean },
		_stateTargets = stateTargets,
		_cascadeResults = {} :: { [Node]: { [string]: CascadeResult } },
		_selections = setmetatable({}, { __mode = "k" }) :: Cascade.SelectionCache,
		_selectorVersions = {} :: { [Node]: number },
		_selectorObservers = {} :: { [Node]: { [Node]: number } },
		_metrics = {} :: { [Node]: Typography.Metrics },
		_scopedStates = if canScopeInputs(settings) then scopedStates else {} :: { [string]: boolean },
	}, StyleRoot)
	if settings.fonts then
		self._fontSubscription = settings.fonts:subscribe(function()
			-- A registered face can change while CSS tokens remain identical.
			self._fontsChanged = true
			self:invalidate()
		end)
	end
	return self
end

function StyleRoot._clearCascades(self: Root)
	table.clear(self._cascadeResults)
	table.clear(self._selectorObservers)
	table.clear(self._logicalMetadata)
	table.clear(self._propertyDefaults)
end

local function observeInputs(self: Root, node: Node, before: { [Node]: number }?, after: { [Node]: number }?)
	for input in before or {} do
		if after and after[input] ~= nil then
			continue
		end
		local observers = self._selectorObservers[input]
		if observers then
			local count = (observers[node] or 0) - 1
			observers[node] = if count > 0 then count else nil
			if next(observers) == nil then
				self._selectorObservers[input] = nil
			end
		end
	end
	for input in after or {} do
		if before and before[input] ~= nil then
			continue
		end
		local observers = self._selectorObservers[input]
		if not observers then
			observers = {}
			self._selectorObservers[input] = observers
		end
		observers[node] = (observers[node] or 0) + 1
	end
end

local function dirtyPath(self: Root, node: Node)
	local current: Node? = node
	while current do
		self._dirtyNodes[current] = true
		current = current.parent
	end
end

function StyleRoot._invalidateInputs(self: Root)
	if canScopeInputs(self._options) then
		self._inputInvalidation = true
		self:_invalidate(false, true)
	else
		self:_invalidate(nil, true)
	end
end

function StyleRoot._invalidate(self: Root, full: boolean?, retainSelectors: boolean?)
	if self._destroyed then
		return
	end
	if full ~= false then
		self._fullInvalidation = true
		if not retainSelectors then
			self:_clearCascades()
		end
	end
	self._revision += 1
	table.clear(self._anonymousStyles)
	if self._pending then
		return
	end
	self._pending = true
	local update = Profiler.wrap(self._options.onProfile, "style.flush", function()
		if self._destroyed then
			return
		end
		self._pending = false
		local revision = self._revision
		local fontsChanged = self._fontsChanged
		self._fontsChanged = false
		local fullInvalidation, dirtyNodes = self._fullInvalidation, self._dirtyNodes
		self._fullInvalidation, self._dirtyNodes = false, {}
		local inputInvalidation = self._inputInvalidation
		self._inputInvalidation = false
		local changedStates = self._changedStates
		self._changedStates = {}
		local ok, failure = pcall(function(): unknown
			WorkQueue.guard(function()
				return not self._destroyed and self._revision == revision
			end, function()
				local cascadeTargets: { [string]: boolean } = {}
				for target, dependencies in self._stateTargets do
					for state in changedStates do
						if dependencies[state] then
							cascadeTargets[target] = true
							break
						end
					end
				end
				local reuseCascades = not fontsChanged
					and canScopeInputs(self._options)
					and (fullInvalidation or inputInvalidation or next(changedStates) ~= nil)
				local trackCascades = canScopeInputs(self._options) and next(self._scopedStates) ~= nil
				local initialFontSize = self._environment.initialFontSize or 16
				local metricsProvider = self._options.fontMetrics
				local fonts = self._options.fonts
				if not metricsProvider and fonts then
					metricsProvider = function(style)
						return fonts:getMetrics(style)
					end
				end
				local computeCascade = Profiler.wrap(self._options.onProfile, "style.match", Cascade.compute)
				local computeValues = Profiler.wrap(self._options.onProfile, "style.values", Variables.compute)
				local computeAxes = Profiler.wrap(self._options.onProfile, "style.axes", Variables.compute)
				local inheritAxes = Profiler.wrap(self._options.onProfile, "style.axes", inheritedAxes)
				local resolveTypography = Profiler.wrap(self._options.onProfile, "style.typography", Typography.resolve)
				local conditionKnown: { [Types.Condition]: boolean } = {}
				local conditionValues: { [Types.Condition]: boolean } = {}
				local conditionEnvironment = self._environment
				local function matchCondition(condition: Types.Condition, target: Node): boolean?
					local callback, supports = self._options.matchCondition, self._options.supportsDeclaration
					if callback then
						local matched = callback(condition, target)
						if matched ~= nil then
							return matched
						end
					end
					-- Custom capabilities can inspect the target node. Keep those calls
					-- live; only built-in media/supports are node-independent here.
					if callback or supports or (condition.name ~= "media" and condition.name ~= "supports") then
						return Conditions.match(condition, self._environment, supports, target)
					end
					if conditionEnvironment ~= self._environment then
						conditionEnvironment = self._environment
						table.clear(conditionKnown)
						table.clear(conditionValues)
					end
					if conditionKnown[condition] then
						return conditionValues[condition]
					end
					local matched = Conditions.match(condition, conditionEnvironment, nil, target)
					conditionKnown[condition] = true
					conditionValues[condition] = matched
					return matched
				end
				local function calculateStyle(
					node: Node,
					parent: ComputedStyle?,
					rootFontSize: number?,
					rootLineHeight: number?,
					parentMetrics: Typography.Metrics?,
					pseudoElement: string?
				): (ComputedStyle, Typography.Metrics?)
					WorkQueue.checkpoint()
					-- Scoped states cannot change selectors with no relevant dependency.
					-- Parent-dependent values still recompute when their context changes.
					-- Full invalidation and reentrant mutations retain the normal path.
					local target = pseudoElement or ""
					local entries = self._cascadeResults[node]
					local cached = if reuseCascades and self._revision == revision
						then entries and entries[target]
						else nil
					local scope = node
					while scope.parent do
						scope = scope.parent
					end
					if cached and (fullInvalidation or inputInvalidation) then
						if not cached.inputs or cached.scope ~= scope then
							cached = nil
						else
							if not sameLocalInputs(cached, node) then
								for input, version in cached.inputs do
									if self._selectorVersions[input] ~= version then
										cached = nil
										break
									end
								end
							end
						end
					elseif cached and cascadeTargets[target] then
						for state in changedStates do
							if cached.states[state] then
								cached = nil
								break
							end
						end
					end
					if
						cached
						and cached.computed
						and self._options.fontSizeKeywords == nil
						and self._options.initialFontMetrics == nil
						and cached.rootFontSize == rootFontSize
						and cached.rootLineHeight == rootLineHeight
						and sameMetrics(cached.parentMetrics, parentMetrics)
					then
						if sameParentInputs(cached, parent, self._sheet.registrations) then
							cached.parent = parent
							return cached.computed, cached.metrics
						elseif parent and (not fonts or Fonts.hasDefaultMetrics(fonts)) then
							local inherited, reads =
								reinheritStyle(cached, parent, self._sheet.properties, self._sheet.registrations)
							if inherited then
								cached.parent, cached.computed, cached.parentReads = parent, inherited, reads
								return inherited, cached.metrics
							end
						end
					end
					local winners: { [string]: Types.Declaration }
					local rollback: Types.Rollback
					local remap: Types.RemapCascade
					if cached then
						winners, rollback, remap = cached.winners, cached.rollback, cached.remap
					else
						local inputs: { [Node]: number } = { [node] = self._selectorVersions[node] }
						-- This observer only records reads, so conjunctive requirements
						-- can reject an unrelated node before a relational traversal.
						winners, rollback, remap = computeCascade(
							self._sheet,
							node,
							matchCondition,
							self._diagnose,
							pseudoElement,
							function(input: Node)
								inputs[input] = self._selectorVersions[input]
							end,
							self._selections,
							true
						)
						if trackCascades and self._revision == revision then
							entries = entries or {}
							self._cascadeResults[node] = entries
							local old = entries[target]
							observeInputs(self, node, old and old.inputs, inputs)
							local states, localInputs
							if
								old
								and old.tag == node.tag
								and old.id == node.id
								and old.className == node.className
							then
								states, localInputs = old.states, old.localInputs
							else
								states, localInputs = StateInvalidation.dependencies(self._sheet, node, pseudoElement)
							end
							entries[target] = {
								inputs = inputs,
								localInputs = localInputs,
								localValues = if localInputs then localValues(node, states) else nil,
								inlineCandidates = node.inlineCandidates,
								scope = scope,
								tag = node.tag,
								id = node.id,
								className = node.className,
								states = states,
								winners = winners,
								rollback = rollback,
								remap = remap,
								values = if old then old.values else nil,
							}
						end
					end
					-- Ordinary descendants need the same inheritance proof as pseudos.
					-- A changed parent paint value does not invalidate an unread value.
					local parentReads: Variables.ParentReads? = if trackCascades
							and self._options.fontSizeKeywords == nil
							and self._options.initialFontMetrics == nil
						then { properties = {}, lookups = {}, variables = {} }
						else nil
					local metadata = self._sheet.properties
					if self._hasLogical then
						-- Writing axes depend on inherited values and computed custom
						-- properties, but not on flow-relative box properties.
						local axisStyle: ComputedStyle
						if winners["writing-mode"] or winners.direction then
							local axes: { [string]: Types.Declaration } = {}
							for property, declaration in winners do
								if
									property == "writing-mode"
									or property == "direction"
									or property:sub(1, 2) == "--"
								then
									axes[property] = declaration
								end
							end
							axisStyle = computeAxes(
								axes,
								parent,
								self._sheet.registrations,
								self._diagnose,
								metadata,
								rollback,
								propertyDefaults(self, metadata),
								parentReads
							)
						else
							-- Inherited computed axes do not rebind to child variables.
							-- Custom properties still compute in the full value pass below.
							axisStyle = inheritAxes(parent, metadata)
						end
						local names, failure = LogicalProperties.names(axisStyle)
						if names then
							winners, rollback = remap(names)
							local reusable = canScopeInputs(self._options)
							local physicalMetadata = if reusable then self._logicalMetadata[names] else nil
							if not physicalMetadata then
								physicalMetadata = table.clone(metadata)
								for logical, physical in names do
									if not physicalMetadata[physical] then
										physicalMetadata[physical] = self._sheet.properties[logical]
									end
								end
								if reusable then
									table.freeze(physicalMetadata)
									self._logicalMetadata[names] = physicalMetadata
								end
							end
							metadata = assert(physicalMetadata)
						else
							self._diagnose("logical-cascade-mapping-pending", failure or "missing-writing-axes", nil)
						end
					end
					local valueEntry = trackCascades
						and self._cascadeResults[node]
						and self._cascadeResults[node][target]
					local valueCache = if valueEntry then valueEntry.values or { entries = {} } else nil
					local computed = computeValues(
						winners,
						parent,
						self._sheet.registrations,
						self._diagnose,
						metadata,
						rollback,
						propertyDefaults(self, metadata),
						parentReads,
						nil,
						valueCache
					)
					if not pseudoElement and not computed.priorities.display and not computed.unresolved.display then
						computed.properties.display = self._displayDefaults[node.tag] or computed.properties.display
					end
					local typographyContext: Typography.Context = {
						initialFontSize = initialFontSize,
						rootFontSize = rootFontSize,
						rootLineHeight = rootLineHeight,
						viewportWidth = self._environment.viewportWidth,
						viewportHeight = self._environment.viewportHeight,
						parentMetrics = parentMetrics,
						fontSizeKeywords = self._options.fontSizeKeywords,
					}
					local resolved, currentMetrics =
						resolveTypography(computed, parent, typographyContext, metricsProvider, self._diagnose)
					if trackCascades and self._revision == revision then
						local results = self._cascadeResults[node]
						if results then
							local entry = results[target]
							if entry then
								entry.values = valueCache
								entry.parentReads = parentReads
								entry.parent, entry.rootFontSize, entry.rootLineHeight =
									parent, rootFontSize, rootLineHeight
								entry.parentMetrics, entry.computed, entry.metrics =
									parentMetrics, resolved, currentMetrics
							end
						end
					end
					return resolved, currentMetrics
				end
				local resolveStyle = Profiler.wrap(self._options.onProfile, "style.resolve", calculateStyle)
				local function visit(
					node: Node,
					parent: ComputedStyle?,
					rootFontSize: number?,
					rootLineHeight: number?,
					parentMetrics: Typography.Metrics?,
					parentChanged: boolean
				)
					if self._destroyed or not self._nodes[node] then
						return
					end
					local previous = self._computed[node]
					if not fullInvalidation and not dirtyNodes[node] and not parentChanged and previous then
						-- Scoped invalidation marks every ancestor of a dirty node. A clean
						-- branch therefore contains no pending styles. If a callback mutated
						-- the root during this pass, retain the prior traversal semantics;
						-- those mutations belong to a separately queued revision.
						if self._revision == revision then
							return
						end
						local metrics = self._metrics[node]
						if not parent then
							rootFontSize = Typography.fontSize(previous)
							rootLineHeight = Typography.lineHeight(previous, metrics)
						end
						for _, child in table.clone(node.children) do
							visit(child, previous, rootFontSize, rootLineHeight, metrics, false)
						end
						return
					end
					local computed, currentMetrics =
						resolveStyle(node, parent, rootFontSize, rootLineHeight, parentMetrics, nil)
					if self._destroyed or not self._nodes[node] then
						return
					end
					local unchanged = not fontsChanged and sameStyle(previous, computed)
					if unchanged then
						computed = previous :: ComputedStyle
					end
					if not parent then
						rootFontSize = Typography.fontSize(computed)
						rootLineHeight = Typography.lineHeight(computed, currentMetrics)
					end
					local pseudos: { [string]: ComputedStyle } = {}
					for name in self._sheet.pseudoElements or {} do
						pseudos[name] = resolveStyle(node, computed, rootFontSize, rootLineHeight, currentMetrics, name)
						if self._destroyed or not self._nodes[node] then
							return
						end
					end
					if self._destroyed or not self._nodes[node] then
						return
					end
					local changed = not unchanged
					local previousPseudos = self._pseudos[node] or {}
					for name, pseudo in pseudos do
						local old = previousPseudos[name]
						if not sameStyle(old, pseudo) then
							changed = true
						elseif not fontsChanged then
							pseudos[name] = old
						end
					end
					for name in previousPseudos do
						if not pseudos[name] then
							changed = true
						end
					end
					self._computed[node] = computed
					self._metrics[node] = currentMetrics
					self._pseudos[node] = pseudos
					if changed and self._options.onStyle then
						self._options.onStyle(node, computed)
					end
					if changed then
						for listener in table.clone(self._listeners) do
							if self._destroyed or not self._nodes[node] then
								break
							end
							if self._listeners[listener] then
								listener(node, computed)
							end
						end
					end
					for _, child in table.clone(node.children) do
						visit(child, computed, rootFontSize, rootLineHeight, currentMetrics, not unchanged)
					end
				end
				for _, node in table.clone(self._roots) do
					local initialMetrics = self._options.initialFontMetrics
					local initialLineHeight = if initialMetrics and initialMetrics.normalLineHeight
						then initialFontSize * initialMetrics.normalLineHeight
						else nil
					visit(node, nil, initialFontSize, initialLineHeight, initialMetrics, false)
				end
				if self._destroyed or revision ~= self._revision then
					return
				end
				self._committedRevision = revision
				for listener in table.clone(self._commitListeners) do
					if self._destroyed or self._revision ~= revision then
						break
					end
					if self._commitListeners[listener] then
						listener(revision)
					end
				end
			end)
			return nil
		end)
		if not ok then
			if WorkQueue.isCancelled(failure) then
				-- The superseding event already queued the next pass. It must also
				-- cover dirty branches consumed by this interrupted computation.
				self._fullInvalidation = true
				self._fontsChanged = self._fontsChanged or fontsChanged
				-- Keep versioned selector observations. The full pass revalidates
				-- their scope/inputs and inherited value context before reuse.
				-- Explicit environment/resource invalidation still clears them.
			else
				error(failure, 0)
			end
		end
	end)
	local run: () -> ()
	run = function()
		if self._pendingUpdate ~= run then return end
		self._pendingUpdate = nil
		self._updating = true
		local ok, problem = pcall(update)
		self._updating = false
		if not ok then error(problem, 0) end
	end
	self._pendingUpdate = run
	if self._workQueue then self._workQueue:defer(run) else task.defer(run) end
end

-- Execute the same pending cascade pass without a deferred/cooperative yield.
-- A suspended preparation is not reentered and no retry/poll loop is added.
function StyleRoot.flushSync(self: Root): (boolean, string?)
	if self._destroyed then return false, "style-root-destroyed" end
	if self._updating and self._workQueue then
		local ok, failure = pcall(function() self._workQueue:flushSync() end)
		if not ok then return false, "synchronous-style-failure:" .. tostring(failure) end
	end
	if self._updating then return false, "style-update-in-progress" end
	local update = self._pendingUpdate
	if update then
		local ok, failure = pcall(function() WorkQueue.atomic(update) end)
		if not ok then return false, "synchronous-style-failure:" .. tostring(failure) end
	end
	if self._revision ~= self._committedRevision then return false, "style-not-synchronously-committed" end
	return true, nil
end

-- Explicit/environment invalidation also discards selector observations.
-- Tree mutations retain them and advance the versions of the inputs changed.
function StyleRoot.invalidate(self: Root, full: boolean?)
	self:_invalidate(full, false)
end

local function touch(self: Root, node: Node?, localChange: boolean?)
	if node then
		self._selectorVersions[node] = (self._selectorVersions[node] or 0) + 1
		dirtyPath(self, node)
		local observers = if not localChange then self._selectorObservers[node] else nil
		if observers then
			for subject in observers do
				dirtyPath(self, subject)
			end
		end
	end
end

local function sameInputs<T>(a: { [string]: T }, b: { [string]: T }): boolean
	for name, value in a do
		if b[name] ~= value then
			return false
		end
	end
	for name in b do
		if a[name] == nil then
			return false
		end
	end
	return true
end

function StyleRoot.setEnvironment(self: Root, environment: Conditions.Environment)
	assert(not self._destroyed, "CSS root has been destroyed")
	self._environment = copyEnvironment(environment)
	self:invalidate()
end

local function invalidateState(self: Root, node: Node)
	dirtyPath(self, node)
	self:invalidate(false)
end

local function onlyScopedStatesChanged(
	node: Node,
	options: NodeOptions,
	scoped: { [string]: boolean },
	allowAttributes: boolean
): boolean
	local states = options.states
	if
		not allowAttributes
		or (options.tag ~= nil and options.tag ~= node.tag)
		or (options.nativeControl ~= nil and options.nativeControl ~= (node.nativeControl or "auto"))
		or (options.id ~= nil and options.id ~= node.id)
		or (options.className ~= nil and options.className ~= node.className)
		or (options.text ~= nil and options.text ~= node.text)
		or (options.textAfter ~= nil and not TextSegments.same(options.textAfter, node.textAfter))
		or (options.inlineStyle ~= nil and not InlineStyle.equal(node.inlineStyle, options.inlineStyle))
	then
		return false
	end
	local changed = false
	for name, value in states or node.states do
		if (value == true) ~= (node.states[name] == true) then
			if not scoped[name] then
				return false
			end
			changed = true
		end
	end
	for name, value in node.states do
		if states and (value == true) ~= (states[name] == true) then
			if not scoped[name] then
				return false
			end
			changed = true
		end
	end
	if options.attributes then
		for name, value in options.attributes do
			if node.attributes[name] ~= value then
				if not allowAttributes or scoped[StateInvalidation.attributeKey(name)] == false then
					return false
				end
				changed = true
			end
		end
		for name, value in node.attributes do
			if options.attributes[name] ~= value then
				if not allowAttributes or scoped[StateInvalidation.attributeKey(name)] == false then
					return false
				end
				changed = true
			end
		end
	end
	return changed
end

function StyleRoot.setId(self: Root, node: Node, id: string?)
	assert(self._nodes[node], "Node belongs to another CSS root or has been removed")
	if node.id == id then
		return
	end
	node.id = id
	touch(self, node)
	self:_invalidateInputs()
end

function StyleRoot.setState(self: Root, node: Node, name: string, active: boolean)
	assert(self._nodes[node], "Node belongs to another CSS root or has been removed")
	if (node.states[name] == true) == active then
		return
	end
	node.states[name] = if active then true else nil
	local scoped = canScopeInputs(self._options) and self._scopedStates[name] == true
	touch(self, node, scoped)
	if scoped then
		self._changedStates[name] = true
		invalidateState(self, node)
	else
		self:_invalidateInputs()
	end
end

function StyleRoot.setAttribute(self: Root, node: Node, name: string, value: string?)
	assert(self._nodes[node], "Node belongs to another CSS root or has been removed")
	if node.attributes[name] == value then
		return
	end
	node.attributes[name] = value
	local key = StateInvalidation.attributeKey(name)
	local scoped = canScopeInputs(self._options) and self._scopedStates[key] ~= false
	touch(self, node, scoped)
	if scoped then
		self._changedStates[key] = true
		invalidateState(self, node)
	else
		self:_invalidateInputs()
	end
end

function StyleRoot._setInlineStyle(self: Root, node: Node, style: Types.InlineStyle?)
	if not style or InlineStyle.equal(node.inlineStyle, style) then
		return
	end
	local copied = InlineStyle.copy(style)
	assert(copied)
	local properties = self._sheet.properties
	local extended = false
	for name, info in copied.properties or {} do
		local previous = properties[name]
		assert(
			not previous or InlineStyle.sameMetadata(previous, info, true),
			`Inline CSS metadata conflicts with stylesheet: {name}`
		)
	end
	for name, info in copied.properties or {} do
		local previous = properties[name]
		if not previous or (previous.animationType == nil and info.animationType ~= nil) then
			if not extended then
				properties = table.clone(properties)
				extended = true
			end
			properties[name] = info
		end
	end
	local candidates = Cascade.prepareInline(copied.declarations, properties, self._diagnose)
	if extended then
		self:_clearCascades()
		self._fullInvalidation = true
	end
	self._sheet.properties = properties
	node.inlineStyle = copied
	node.inlineCandidates = if #candidates > 0 then candidates else nil
	if not self._hasLogical then
		for _, candidate in candidates do
			if self._logicalNames[candidate.declaration.property] then
				self._hasLogical = true
				self:_clearCascades()
				self._fullInvalidation = true
				break
			end
		end
	end
end

function StyleRoot.add(self: Root, options: NodeOptions?, parent: Node?): Node
	assert(not self._destroyed, "CSS root has been destroyed")
	assert(not parent or self._nodes[parent], "Parent belongs to another CSS root")
	local props: NodeOptions = options or {}
	assert(
		props.nativeControl == nil or props.nativeControl == "auto" or props.nativeControl == "button",
		"Unknown native control"
	)
	local className = props.className or ""
	local node: Node = {
		tag = props.tag or "div",
		nativeControl = props.nativeControl or "auto",
		id = props.id,
		className = className,
		classes = classSet(className),
		attributes = table.clone(props.attributes or {}),
		states = table.clone(props.states or {}),
		text = props.text or "",
		textAfter = TextSegments.copy(props.textAfter),
		parent = parent,
		children = {},
	}
	if props.inlineStyle then
		self:_setInlineStyle(node, props.inlineStyle)
	end
	self._nodes[node] = true
	self._selectorVersions[node] = 0
	table.insert(if parent then parent.children else self._roots, node)
	touch(self, node)
	touch(self, parent)
	self:_invalidateInputs()
	return node
end

function StyleRoot.update(self: Root, node: Node, options: NodeOptions)
	assert(self._nodes[node], "Node belongs to another CSS root or has been removed")
	local textAfter = TextSegments.copy(options.textAfter)
	assert(
		options.nativeControl == nil or options.nativeControl == "auto" or options.nativeControl == "button",
		"Unknown native control"
	)
	if
		(options.tag == nil or options.tag == node.tag)
		and (options.nativeControl == nil or options.nativeControl == (node.nativeControl or "auto"))
		and (options.id == nil or options.id == node.id)
		and (options.className == nil or options.className == node.className)
		and (options.text == nil or options.text == node.text)
		and (options.textAfter == nil or TextSegments.same(options.textAfter, node.textAfter))
		and (options.attributes == nil or sameInputs(node.attributes, options.attributes))
		and (options.states == nil or sameInputs(node.states, options.states))
		and (options.inlineStyle == nil or InlineStyle.equal(node.inlineStyle, options.inlineStyle))
	then
		return
	end
	local scoped = onlyScopedStatesChanged(node, options, self._scopedStates, canScopeInputs(self._options))
	touch(self, node, scoped)
	local previousStates = node.states
	local previousAttributes = node.attributes
	if options.inlineStyle then
		self:_setInlineStyle(node, options.inlineStyle)
	end
	if options.tag ~= nil then
		node.tag = options.tag
	end
	if options.nativeControl ~= nil then
		node.nativeControl = options.nativeControl
	end
	if options.id ~= nil then
		node.id = options.id
	end
	if options.className ~= nil then
		node.className = options.className
		node.classes = classSet(options.className)
	end
	if options.attributes ~= nil then
		node.attributes = table.clone(options.attributes)
	end
	if options.states ~= nil then
		node.states = table.clone(options.states)
	end
	if options.text ~= nil then
		node.text = options.text
	end
	if options.textAfter ~= nil then
		node.textAfter = textAfter
	end
	if scoped then
		for name, value in previousAttributes do
			if node.attributes[name] ~= value then
				self._changedStates[StateInvalidation.attributeKey(name)] = true
			end
		end
		for name, value in node.attributes do
			if previousAttributes[name] ~= value then
				self._changedStates[StateInvalidation.attributeKey(name)] = true
			end
		end
		for name, value in previousStates do
			if (value == true) ~= (node.states[name] == true) then
				self._changedStates[name] = true
			end
		end
		for name, value in node.states do
			if (value == true) ~= (previousStates[name] == true) then
				self._changedStates[name] = true
			end
		end
		invalidateState(self, node)
	else
		self:_invalidateInputs()
	end
end

function StyleRoot.reparent(self: Root, node: Node, parent: Node?)
	assert(self._nodes[node] and (not parent or self._nodes[parent]), "Node belongs to another CSS root")
	if node.parent == parent then
		return
	end
	local ancestor = parent
	while ancestor do
		assert(ancestor ~= node, "Cannot create a CSS tree cycle")
		ancestor = ancestor.parent
	end
	local previous = if node.parent then node.parent.children else self._roots
	touch(self, node.parent)
	touch(self, parent)
	touch(self, node)
	local index = table.find(previous, node)
	if index then
		table.remove(previous, index)
	end
	node.parent = parent
	table.insert(if parent then parent.children else self._roots, node)
	local function moved(target: Node)
		self._dirtyNodes[target] = true
		for _, child in target.children do
			moved(child)
		end
	end
	moved(node)
	dirtyPath(self, node)
	self:_invalidateInputs()
end

function StyleRoot.remove(self: Root, node: Node)
	if not self._nodes[node] then
		return
	end
	local siblings = if node.parent then node.parent.children else self._roots
	touch(self, node.parent)
	local index = table.find(siblings, node)
	if index then
		table.remove(siblings, index)
	end
	local function discard(target: Node)
		touch(self, target)
		for _, entry in self._cascadeResults[target] or {} do
			observeInputs(self, target, entry.inputs, nil)
		end
		self._nodes[target] = nil
		self._computed[target] = nil
		self._pseudos[target] = nil
		self._metrics[target] = nil
		self._dirtyNodes[target] = nil
		self._cascadeResults[target] = nil
		self._selectorVersions[target] = nil
		self._selectorObservers[target] = nil
		for _, child in target.children do
			discard(child)
		end
	end
	discard(node)
	self:_invalidateInputs()
end

-- Replace source order without replacing logical identity. Validate the entire
-- permutation before mutating it so sibling selectors never see a partial list.
function StyleRoot.reorder(self: Root, parent: Node?, children: { Node })
	assert(not self._destroyed, "CSS root has been destroyed")
	assert(not parent or self._nodes[parent], "Parent belongs to another CSS root")
	local siblings = if parent then parent.children else self._roots
	assert(#children == #siblings, "Reorder requires every current sibling exactly once")
	local seen: { [Node]: boolean } = {}
	local changed = false
	for index, child in children do
		assert(self._nodes[child] and child.parent == parent and not seen[child], "Invalid sibling permutation")
		seen[child] = true
		changed = changed or siblings[index] ~= child
	end
	if not changed then
		return
	end
	local ordered = table.clone(children)
	table.clear(siblings)
	for _, child in ordered do
		table.insert(siblings, child)
	end
	touch(self, parent)
	self:_invalidateInputs()
end

function StyleRoot.getComputedPseudoStyle(self: Root, node: Node, name: string): ComputedStyle?
	local pseudos = self._pseudos[node]
	return if pseudos then pseudos[name] else nil
end

function StyleRoot.getComputedStyle(self: Root, node: Node): ComputedStyle?
	return self._computed[node]
end

function StyleRoot.getKeyframes(self: Root, node: Node, name: string): (Types.PreparedKeyframes?, string?)
	if self._destroyed or not self._nodes[node] then
		return nil, "unknown-keyframes-node"
	end
	local definition, failure = Cascade.getKeyframes(self._sheet, name, node, function(condition, target)
		local callback = self._options.matchCondition
		local matched = if callback then callback(condition, target) else nil
		return if matched ~= nil
			then matched
			else Conditions.match(condition, self._environment, self._options.supportsDeclaration, target)
	end)
	if self._destroyed or not self._nodes[node] then
		return nil, "unknown-keyframes-node"
	end
	return if definition then Keyframes.copy(definition) else nil, failure
end

-- Resolve endpoint tokens against the current target context. Numerical
-- computation/interpolation remains the consuming backend's job.
function StyleRoot.getAnimationTracks(
	self: Root,
	node: Node,
	name: string,
	easing: Easing.Curve,
	pseudo: string?
): (AnimationTracks.Result?, string?)
	local definition, failure = self:getKeyframes(node, name)
	if not definition then
		return nil, failure
	end
	local current = if pseudo then self:getComputedPseudoStyle(node, pseudo) else self._computed[node]
	if not current or self._committedRevision ~= self._revision then
		return nil, "animation-style-not-computed"
	end
	return AnimationTracks.resolve(definition, {
		style = current,
		parent = if pseudo then self._computed[node] elseif node.parent then self._computed[node.parent] else nil,
		metadata = self._sheet.properties,
		registrations = self._sheet.registrations,
		defaults = propertyDefaults(self, self._sheet.properties),
	}, easing)
end

-- Anonymous formatting boxes inherit without matching selectors or becoming
-- logical children. Reuse registration defaults and the normal typography path.
function StyleRoot.getAnonymousStyle(self: Root, parentNode: Node): (ComputedStyle?, string?)
	local parent = if self._nodes[parentNode] then self._computed[parentNode] else nil
	if self._destroyed or not parent then
		return nil, "unknown-anonymous-style-parent"
	end
	local revision = self._revision
	local cacheable = self._options.fontMetrics == nil and self._committedRevision == revision
	local cached = if cacheable then self._anonymousStyles[parentNode] else nil
	if cached then
		return copyStyle(cached), nil
	end
	local computed = Variables.compute(
		{},
		parent,
		self._sheet.registrations,
		self._diagnose,
		self._sheet.properties,
		nil,
		propertyDefaults(self, self._sheet.properties)
	)
	local metricsProvider = self._options.fontMetrics
	if not metricsProvider and self._options.fonts then
		local fonts = self._options.fonts
		metricsProvider = function(style)
			return fonts:getMetrics(style)
		end
	end
	local root = parentNode
	while root.parent do
		root = root.parent
	end
	local rootStyle = self._computed[root]
	local rootMetrics = if metricsProvider and rootStyle then metricsProvider(rootStyle) else nil
	local resolved = Typography.resolve(computed, parent, {
		initialFontSize = self._environment.initialFontSize or 16,
		rootFontSize = if rootStyle then Typography.fontSize(rootStyle) else nil,
		rootLineHeight = if rootStyle then Typography.lineHeight(rootStyle, rootMetrics) else nil,
		viewportWidth = self._environment.viewportWidth,
		viewportHeight = self._environment.viewportHeight,
		parentMetrics = if metricsProvider then metricsProvider(parent) else nil,
		fontSizeKeywords = self._options.fontSizeKeywords,
	}, metricsProvider, self._diagnose)
	if cacheable and not self._destroyed and self._revision == revision then
		-- Formatters can add non-inherited properties to their anonymous box.
		-- Keep the computed snapshot private and give each caller fresh maps.
		self._anonymousStyles[parentNode] = resolved
		return copyStyle(resolved), nil
	end
	return resolved, nil
end

function StyleRoot.subscribe(self: Root, listener: (Node, ComputedStyle) -> ()): () -> ()
	assert(not self._destroyed, "CSS root has been destroyed")
	self._listeners[listener] = true
	return function()
		self._listeners[listener] = nil
	end
end

function StyleRoot.getRevision(self: Root): (number, number)
	return self._revision, self._committedRevision
end

function StyleRoot.subscribeCommit(self: Root, listener: (number) -> ()): () -> ()
	assert(not self._destroyed, "CSS root has been destroyed")
	self._commitListeners[listener] = true
	return function()
		self._commitListeners[listener] = nil
	end
end

function StyleRoot.destroy(self: Root)
	self._destroyed = true
	self._pendingUpdate = nil
	self._workQueue = nil
	if self._fontSubscription then
		self._fontSubscription()
		self._fontSubscription = nil
	end
	table.clear(self._roots)
	table.clear(self._nodes)
	table.clear(self._computed)
	table.clear(self._pseudos)
	table.clear(self._anonymousStyles)
	table.clear(self._metrics)
	table.clear(self._dirtyNodes)
	table.clear(self._changedStates)
	table.clear(self._stateTargets)
	table.clear(self._cascadeResults)
	table.clear(self._logicalMetadata)
	table.clear(self._propertyDefaults)
	table.clear(self._selections)
	table.clear(self._selectorVersions)
	table.clear(self._selectorObservers)
	table.clear(self._scopedStates)
	table.clear(self._displayDefaults)
	table.clear(self._variableDefaults.values)
	table.clear(self._variableDefaults.pending)
	for _, rule in self._sheet.rules do
		if rule.candidates then
			table.clear(rule.candidates)
		end
	end
	self._sheet.keyframes = nil
	table.clear(self._listeners)
	table.clear(self._commitListeners)
end

export type Root = typeof(setmetatable(
	{} :: {
		_sheet: Types.PreparedSheet,
		_variableDefaults: Variables.Defaults,
		_propertyDefaults: { [{ [string]: Types.PropertyMetadata }]: Variables.Defaults },
		_hasLogical: boolean,
		_displayDefaults: { [string]: { Types.ValueToken } },
		_logicalNames: { [string]: string },
		_logicalMetadata: { [{ [string]: string }]: { [string]: Types.PropertyMetadata } },
		_diagnose: Types.Diagnose,
		_options: RootOptions,
		_environment: Conditions.Environment,
		_nodes: { [Node]: boolean },
		_computed: { [Node]: ComputedStyle },
		_pseudos: { [Node]: { [string]: ComputedStyle } },
		_anonymousStyles: { [Node]: ComputedStyle },
		_roots: { Node },
		_listeners: { [(Node, ComputedStyle) -> ()]: boolean },
		_commitListeners: { [(number) -> ()]: boolean },
		_revision: number,
		_committedRevision: number,
		_pending: boolean,
		_pendingUpdate: (() -> ())?,
		_updating: boolean,
		_workQueue: WorkQueue.Queue?,
		_destroyed: boolean,
		_fontSubscription: (() -> ())?,
		_fontsChanged: boolean,
		_fullInvalidation: boolean,
		_inputInvalidation: boolean,
		_dirtyNodes: { [Node]: boolean },
		_changedStates: { [string]: boolean },
		_stateTargets: StateInvalidation.Targets,
		_cascadeResults: { [Node]: { [string]: CascadeResult } },
		_selections: Cascade.SelectionCache,
		_selectorVersions: { [Node]: number },
		_selectorObservers: { [Node]: { [Node]: number } },
		_metrics: { [Node]: Typography.Metrics },
		_scopedStates: { [string]: boolean },
	},
	StyleRoot
))

return { createRoot = StyleRoot.new }
