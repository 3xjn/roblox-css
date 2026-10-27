--!strict

local Types = require(script.Parent.Types)
local Selectors = require(script.Parent.Selectors)
local SelectorIndex = require(script.Parent.SelectorIndex)

type Token = Types.SelectorToken

-- Selector attribute inputs share the existing dependency graph. The prefix
-- keeps them distinct from the native interaction state names.
local function attributeKey(name: string): string
	return "@" .. name
end

local function dependency(token: Token): string?
	if token.kind == "attribute" and token.attribute then
		return attributeKey(token.attribute)
	end
	return if token.kind == "pseudo" then Selectors.stateDependencies[token.value] else nil
end

-- Scoped updates dirty the changed node and all ancestors. A selector is safe
-- only when a state change cannot affect a subject outside that ancestor path.
local function markAll(tokens: { Token }, scoped: { [string]: boolean })
	for _, token in tokens do
		local state = dependency(token)
		if state then
			scoped[state] = false
		end
		if token.children then
			markAll(token.children, scoped)
		end
		if token.nth and token.nth.of then
			markAll(token.nth.of, scoped)
		end
	end
end

local analyze: ({ Token }, { [string]: boolean }, boolean, boolean) -> ()
analyze = function(tokens: { Token }, scoped: { [string]: boolean }, compound: boolean, insideHas: boolean)
	local lastCombinator = 0
	for index, token in tokens do
		if token.kind == "combinator" then
			lastCombinator = index
		end
	end
	if compound and lastCombinator > 0 then
		markAll(tokens, scoped)
		return
	end
	for index, token in tokens do
		local state = dependency(token)
		if state and index <= lastCombinator then
			scoped[state] = false
		end
		if token.nth and token.nth.of then
			-- State-dependent filtering changes the ranks of other siblings.
			markAll(token.nth.of, scoped)
		end
		local children = token.children
		if not children or #children == 0 then
			continue
		end
		if index <= lastCombinator then
			markAll(children, scoped)
		elseif token.kind == "selector" then
			analyze(children, scoped, compound, insideHas)
		elseif token.value == ":is" or token.value == ":where" or token.value == ":not" then
			for _, branch in children do
				analyze(branch.children or {}, scoped, true, insideHas)
			end
		elseif token.value == ":has" and not insideHas then
			for _, branch in children do
				local parts: { Token } = branch.children or {}
				local first = 1
				while parts[first] and parts[first].kind == "comment" do
					first += 1
				end
				local leading = parts[first]
				if leading and leading.kind == "combinator" then
					local relation = leading.value:match("^%s*(.-)%s*$") or ""
					if relation ~= ">" and relation ~= "" then
						markAll(parts :: { Token }, scoped)
						continue
					end
					first += 1
				end
				-- One descendant/child compound keeps every affected subject on
				-- the changed node's ancestor path. Other relations fall back.
				local subject: { Token } = {}
				for partIndex = first, #parts do
					table.insert(subject, parts[partIndex])
				end
				analyze(subject, scoped, true, true)
			end
		else
			markAll(children, scoped)
		end
	end
end

export type Targets = { [string]: { [string]: boolean } }

local StateInvalidation = {}
StateInvalidation.attributeKey = attributeKey

local function collectStates(tokens: { Token }, states: { [string]: boolean })
	for _, token in tokens do
		local state = dependency(token)
		if state then
			states[state] = true
		end
		if token.children then
			collectStates(token.children, states)
		end
		if token.nth and token.nth.of then
			collectStates(token.nth.of, states)
		end
	end
end

function StateInvalidation.prepare(sheet: Types.PreparedSheet): ({ [string]: boolean }, Targets)
	local scoped: { [string]: boolean } = {}
	for _, state in Selectors.stateDependencies do
		scoped[state] = true
	end
	-- Seed every known input before applying unsafe-relation exclusions. An
	-- attribute absent from all selectors has no selector dependencies.
	for _, rule in sheet.rules do
		for _, selector in rule.selectors do
			collectStates(selector.tokens, scoped)
		end
	end
	local targets: Targets = {}
	for _, rule in sheet.rules do
		for _, selector in rule.selectors do
			analyze(selector.tokens, scoped, false, false)
			local target = selector.pseudoElement or ""
			local states = targets[target] or {}
			targets[target] = states
			collectStates(selector.tokens, states)
		end
	end
	return scoped, targets
end

-- An indexed candidate can still fail matching, so include every input read by
-- every selector for this target in those rules. Classes, IDs and tags cannot
-- change during a scoped state update; changes to them require a full pass.
function StateInvalidation.dependencies(
	sheet: Types.PreparedSheet,
	node: Types.Node,
	target: string?
): ({ [string]: boolean }, boolean)
	local indices: { number } = {}
	if sheet.selectorIndex then
		indices = SelectorIndex.candidates(sheet.selectorIndex, node, target)
	else
		for index in sheet.rules do
			table.insert(indices, index)
		end
	end
	local states: { [string]: boolean } = {}
	local localInputs = true
	for _, index in indices do
		for _, selector in sheet.rules[index].selectors do
			if selector.pseudoElement == target then
				collectStates(selector.tokens, states)
				localInputs = localInputs and Selectors.localInputs(selector.tokens)
			end
		end
	end
	return states, localInputs
end

return StateInvalidation
