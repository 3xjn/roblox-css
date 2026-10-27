--!strict

local Types = require(script.Parent.Types)
type Token = Types.SelectorToken
type Node = Types.Node
export type Observer = (Node) -> ()

local Selectors = {}

-- These browser-specific subjects have no corresponding Roblox target. They
-- remain valid selectors, but cannot select a node in this renderer.
local function unavailablePseudo(value: string): boolean
	return value == ":host" or value == ":host-context"
		or value:sub(1, 9) == ":-webkit-" or value:sub(1, 6) == ":-moz-"
end

local pseudoElements: { [string]: string } = {
	["::placeholder"] = "placeholder",
	["::before"] = "before",
	["::after"] = "after",
	[":before"] = "before",
	[":after"] = "after",
}

-- Split only a terminal tree-abiding pseudo-element. Matching keeps the real
-- originating node as the subject; structural selectors never see fake children.
function Selectors.splitTarget(tokens: { Token }): ({ Token }?, string?, string?)
	local origin: { Token } = {}
	local target: string? = nil
	for _, token in tokens do
		if token.kind == "comment" then
			table.insert(origin, token)
		elseif target then
			return nil, nil, "Selectors after a pseudo-element require additional matching support"
		elseif token.kind == "pseudo" and (token.value:sub(1, 2) == "::" or pseudoElements[token.value]) then
			target = pseudoElements[token.value]
			if not target and (token.value == "::backdrop" or token.value == "::file-selector-button"
				or token.value:sub(1, 10) == "::-webkit-" or token.value:sub(1, 7) == "::-moz-") then
				return {}, "unavailable", nil
			end
			if not target or token.children and #token.children > 0 then
				return nil, nil, "Unsupported pseudo-element"
			end
			local previous: Token? = nil
			for index = #origin, 1, -1 do
				if origin[index].kind ~= "comment" then
					previous = origin[index]
					break
				end
			end
			if not previous or previous.kind == "combinator" then
				table.insert(origin, { kind = "universal", value = "*" })
			end
		else
			table.insert(origin, token)
		end
	end
	return origin, target, nil
end

local structural: { [string]: boolean } = {
	[":root"] = true,
	[":scope"] = true,
	[":empty"] = true,
	[":first-child"] = true,
	[":last-child"] = true,
	[":only-child"] = true,
	[":first-of-type"] = true,
	[":last-of-type"] = true,
	[":only-of-type"] = true,
}

local states: { [string]: string } = {
	[":hover"] = "hover",
	[":active"] = "active",
	[":focus"] = "focus",
	[":focus-visible"] = "focus-visible",
	[":focus-within"] = "focus",
	[":disabled"] = "disabled",
	[":enabled"] = "enabled",
	[":checked"] = "checked",
	[":indeterminate"] = "indeterminate",
	[":required"] = "required",
	[":optional"] = "optional",
	[":read-only"] = "read-only",
	[":read-write"] = "read-write",
	[":placeholder-shown"] = "placeholder-shown",
	[":valid"] = "valid",
	[":invalid"] = "invalid",
	[":autofill"] = "autofill",
	[":-webkit-autofill"] = "autofill",
}

-- Shared with invalidation analysis: these are the actual logical state inputs
-- read by the matcher, including aliases and implicit focus-within ancestry.
Selectors.stateDependencies = table.freeze(states)

local functions: { [string]: boolean } = { [":is"] = true, [":where"] = true, [":not"] = true, [":has"] = true }
local nthPseudos: { [string]: boolean } = {
	[":nth-child"] = true,
	[":nth-last-child"] = true,
	[":nth-of-type"] = true,
	[":nth-last-of-type"] = true,
}
local operators: { [string]: boolean } =
	{ ["="] = true, ["~="] = true, ["|="] = true, ["^="] = true, ["$="] = true, ["*="] = true }

local function validateSequence(tokens: { Token }, relative: boolean): string?
	local seen = false
	local afterCombinator = false
	for _, token in tokens do
		if token.kind == "comment" then
			continue
		end
		if token.kind == "combinator" then
			if afterCombinator then
				return "Consecutive selector combinators are invalid"
			end
			if not seen and not relative then
				return "Relative selector is only supported as a :has argument"
			end
			afterCombinator = true
		else
			afterCombinator = false
		end
		seen = true
	end
	if not seen then
		return "Empty selector"
	end
	return if afterCombinator then "Trailing selector combinator is invalid" else nil
end

-- Validate before matching so an unsupported branch inside :not cannot turn true.
function Selectors.validate(tokens: { Token }, relative: boolean?): string?
	local sequenceFailure = validateSequence(tokens, relative == true)
	if sequenceFailure then
		return sequenceFailure
	end
	for _, token in tokens do
		if token.namespace ~= nil then
			return "Namespaced selectors are not implemented"
		end
		if token.kind == "pseudo" then
			if token.value == ":dir" then
				local selectors = token.children
				local argument = if selectors and #selectors == 1 then selectors[1].children else nil
				if not argument or #argument ~= 1 or argument[1].kind ~= "tag"
					or (argument[1].value ~= "ltr" and argument[1].value ~= "rtl") then
					return "Invalid :dir argument"
				end
				continue
			elseif unavailablePseudo(token.value) and not states[token.value] then
				continue
			elseif nthPseudos[token.value] then
				local nth = token.nth
				if not nth or token.nthError then
					return token.nthError or "Compiled nth formula required"
				end
				for _, coefficient in { nth.a, nth.b } do
					if
						coefficient ~= coefficient
						or coefficient % 1 ~= 0
						or coefficient < -2147483648
						or coefficient > 2147483647
					then
						return "Unsupported nth coefficient"
					end
				end
				if nth.of then
					if string.find(token.value, "of-type", 1, true) then
						return "of-selector filter is invalid in nth-of-type"
					end
					if #nth.of == 0 then
						return "Empty nth of-selector list"
					end
					for _, selector in nth.of do
						local children = selector.children
						if selector.kind ~= "selector" or not children or #children == 0 then
							return "Invalid nth of-selector"
						end
						for _, child in children do
							if child.kind == "comment" then
								continue
							end
							if child.kind == "combinator" then
								return "Relative nth of-selector is invalid"
							end
							break
						end
					end
					local failure = Selectors.validate(nth.of)
					if failure then
						return failure
					end
				end
			elseif not structural[token.value] and not states[token.value] and not functions[token.value] then
				return `Unsupported pseudo selector {token.value}`
			elseif functions[token.value] then
				if not token.children or #token.children == 0 then
					return "Functional pseudo requires selector arguments"
				end
				for _, selector in token.children do
					if selector.kind ~= "selector" or not selector.children or #selector.children == 0 then
						return "Empty or invalid functional selector argument"
					end
					local failure = Selectors.validate(selector.children, token.value == ":has")
					if failure then
						return failure
					end
				end
				-- Arguments were validated in their own relative-selector context.
				continue
			elseif token.children and #token.children > 0 then
				return `Unexpected pseudo selector arguments {token.value}`
			end
		elseif token.kind == "combinator" then
			local value = token.value:match("^%s*(.-)%s*$") or ""
			if value ~= "" and value ~= ">" and value ~= "+" and value ~= "~" then
				return `Unsupported combinator {value}`
			end
		elseif token.kind == "attribute" then
			if token.operator and not operators[token.operator] then
				return `Unsupported attribute operator {token.operator}`
			end
		elseif
			token.kind ~= "class"
			and token.kind ~= "id"
			and token.kind ~= "tag"
			and token.kind ~= "universal"
			and token.kind ~= "selector"
			and token.kind ~= "comment"
		then
			return `Unsupported selector token {token.kind}`
		end
		-- Pseudo arguments were handled above. Nonfunctional parser tokens may
		-- carry an empty children array; it is not an empty selector branch.
		if token.children and token.kind ~= "pseudo" then
			local failure = Selectors.validate(token.children)
			if failure then
				return failure
			end
		end
	end
	return nil
end

local function previous(node: Node, observe: Observer?): Node?
	if observe then
		observe(node)
	end
	local parent = node.parent
	if not parent then
		return nil
	end
	if observe then
		observe(parent)
	end
	local index = table.find(parent.children, node)
	return if index and index > 1 then parent.children[index - 1] else nil
end

local function attributeMatches(token: Token, node: Node): boolean
	local name = token.attribute or ""
	local value = if name == "class" then node.className elseif name == "id" then node.id else node.attributes[name]
	if value == nil then
		return false
	end
	if token.operator == nil then
		return true
	end
	local expected = token.value
	if token.insensitive then
		value = string.lower(value)
		expected = string.lower(expected)
	end
	if token.operator == "=" then
		return value == expected
	end
	if expected == "" then
		return false
	end
	if token.operator == "~=" then
		for word in value:gmatch("[^\t\n\f\r ]+") do
			if word == expected then
				return true
			end
		end
		return false
	end
	if token.operator == "|=" then
		return value == expected or value:sub(1, #expected + 1) == expected .. "-"
	end
	if token.operator == "^=" then
		return value:sub(1, #expected) == expected
	end
	if token.operator == "$=" then
		return value:sub(-#expected) == expected
	end
	return string.find(value, expected, 1, true) ~= nil
end

local function subtreeState(node: Node, state: string, observe: Observer?): boolean
	if observe then
		observe(node)
	end
	if node.states[state] then
		return true
	end
	for _, child in node.children do
		if subtreeState(child, state, observe) then
			return true
		end
	end
	return false
end

local matches: ({ Token }, Node, Node, Observer?, boolean?) -> boolean

local function anySelector(
	children: { Token },
	node: Node,
	scope: Node,
	observe: Observer?,
	anchorsFirst: boolean?
): boolean
	for _, selector in children do
		if selector.kind == "selector" and matches(selector.children or {}, node, scope, observe, anchorsFirst) then
			return true
		end
	end
	return false
end

local function nthMatches(token: Token, node: Node, scope: Node, observe: Observer?, anchorsFirst: boolean?): boolean
	local nth = token.nth
	if not nth then
		return false
	end
	local siblings = if node.parent then node.parent.children else { node }
	if observe and node.parent then
		observe(node.parent)
	end
	local ofType = string.find(token.value, "of-type", 1, true) ~= nil
	local count, rank = 0, 0
	for _, sibling in siblings do
		if observe then
			observe(sibling)
		end
		if ofType and sibling.tag ~= node.tag then
			continue
		end
		if nth.of and not anySelector(nth.of, sibling, scope, observe, anchorsFirst) then
			continue
		end
		count += 1
		if sibling == node then
			rank = count
		end
	end
	if rank == 0 then
		return false
	end
	if token.value == ":nth-last-child" or token.value == ":nth-last-of-type" then
		rank = count - rank + 1
	end
	if nth.a == 0 then
		return rank == nth.b
	end
	local step = (rank - nth.b) / nth.a
	return step >= 0 and step % 1 == 0
end

local function hasRelative(children: { Token }, anchor: Node, observe: Observer?, anchorsFirst: boolean?): boolean
	for _, selector in children do
		local tokens: { Token } = selector.children or {}
		local leading: Token? = nil
		local start = 1
		for index, token in tokens do
			if token.kind ~= "comment" then
				leading = token
				start = if token.kind == "combinator" then index + 1 else 1
				break
			end
		end
		local relation = if leading and leading.kind == "combinator" then leading.value:match("^%s*(.-)%s*$") else ""
		local compound = anchorsFirst == true and (relation == "" or relation == ">")
		if compound then
			for index = start, #tokens do
				if tokens[index].kind == "combinator" then
					compound = false
					break
				end
			end
		end
		local relative: { Token } = if compound and start == 1 then tokens else {}
		if compound then
			-- The search already proves this candidate's relation to the anchor.
			-- Prepared observers only record reads; omit the synthetic :scope
			-- prefix and, for a child compound, searching deeper descendants.
			if start ~= 1 then
				for index = start, #tokens do
					table.insert(relative, tokens[index])
				end
			end
		else
			table.insert(relative, { kind = "pseudo", value = ":scope" })
			if not leading or leading.kind ~= "combinator" then
				table.insert(relative, { kind = "combinator", value = " " })
			end
			for _, token in tokens do
				table.insert(relative, token)
			end
		end
		local directChildren = compound and relation == ">"
		local function visit(candidate: Node): boolean
			if observe then
				observe(candidate)
			end
			if matches(relative, candidate, anchor, observe, anchorsFirst) then
				return true
			end
			if not directChildren then
				for _, child in candidate.children do
					if visit(child) then
						return true
					end
				end
			end
			return false
		end
		-- A sibling-relative selector can only reach following siblings and their
		-- descendants. Observing the whole document makes unrelated changes
		-- invalidate every selector that uses :has(+ ...) or :has(~ ...).
		if relation == "+" or relation == "~" then
			local parent = anchor.parent
			if parent then
				if observe then
					observe(parent)
				end
				local anchorIndex = table.find(parent.children, anchor)
				if anchorIndex then
					for index = anchorIndex + 1, #parent.children do
						if visit(parent.children[index]) then
							return true
						end
					end
				end
			end
		else
			if observe then
				observe(anchor)
			end
			for _, child in anchor.children do
				if visit(child) then
					return true
				end
			end
		end
	end
	return false
end

local function structuralMatches(value: string, node: Node, scope: Node, observe: Observer?): boolean
	if value == ":root" then
		return node.parent == nil
	end
	if value == ":scope" then
		return node == scope
	end
	if value == ":empty" then
		return #node.children == 0 and node.text == ""
	end
	local siblings = if node.parent then node.parent.children else { node }
	if observe and node.parent then
		observe(node.parent)
	end
	local first = true
	local last = true
	local seen = false
	local ofType = string.find(value, "of-type", 1, true) ~= nil
	for _, sibling in siblings do
		if observe then
			observe(sibling)
		end
		if sibling == node then
			seen = true
		elseif not ofType or sibling.tag == node.tag then
			if seen then
				last = false
			else
				first = false
			end
		end
	end
	if value == ":first-child" or value == ":first-of-type" then
		return first
	end
	if value == ":last-child" or value == ":last-of-type" then
		return last
	end
	return first and last
end

local function simpleMatches(token: Token, node: Node, scope: Node, observe: Observer?, anchorsFirst: boolean?): boolean
	if observe then
		observe(node)
	end
	if token.kind == "class" then
		return node.classes[token.value] == true
	end
	if token.kind == "id" then
		return node.id == token.value
	end
	if token.kind == "tag" then
		return node.tag == token.value
	end
	if token.kind == "universal" or token.kind == "comment" then
		return true
	end
	if token.kind == "attribute" then
		return attributeMatches(token, node)
	end
	if token.kind == "pseudo" then
		local value = token.value
		if value == ":dir" then
			local wanted = assert(assert(token.children)[1].children)[1].value
			local current: Node? = node
			while current do
				if observe then observe(current) end
				local direction = current.attributes.dir
				if type(direction) == "string" then
					direction = string.lower(direction)
					if direction == "ltr" or direction == "rtl" then return direction == wanted end
				end
				current = current.parent
			end
			return wanted == "ltr"
		end
		if value == ":is" or value == ":where" then
			return anySelector(token.children or {}, node, scope, observe, anchorsFirst)
		end
		if value == ":not" then
			return not anySelector(token.children or {}, node, scope, observe, anchorsFirst)
		end
		if value == ":has" then
			return hasRelative(token.children or {}, node, observe, anchorsFirst)
		end
		if nthPseudos[value] then
			return nthMatches(token, node, scope, observe, anchorsFirst)
		end
		if structural[value] then
			return structuralMatches(value, node, scope, observe)
		end
		local state = states[value]
		if state == "hover" or state == "active" or value == ":focus-within" then
			return subtreeState(node, state, observe)
		end
		return state ~= nil and node.states[state] == true
	end
	return false
end

local anchors = { class = true, id = true, tag = true, attribute = true }

matches = function(tokens: { Token }, node: Node, scope: Node, observe: Observer?, anchorsFirst: boolean?): boolean
	local function matchAt(index: number, candidate: Node): boolean
		local guarded = false
		while index > 0 and tokens[index].kind ~= "combinator" do
			local token = tokens[index]
			if anchorsFirst and not guarded and token.kind == "pseudo" then
				-- Reject remaining cheap requirements before a predicate can
				-- traverse the tree. Plain class/id/tag compounds need no extra
				-- scan. Recording the rejecting node keeps future changes live.
				local cursor = index - 1
				while cursor > 0 and tokens[cursor].kind ~= "combinator" do
					local requirement = tokens[cursor]
					if
						anchors[requirement.kind]
						and not simpleMatches(requirement, candidate, scope, observe, anchorsFirst)
					then
						return false
					end
					cursor -= 1
				end
				guarded = true
			end
			if
				not (guarded and anchors[token.kind])
				and not simpleMatches(token, candidate, scope, observe, anchorsFirst)
			then
				return false
			end
			index -= 1
		end
		if index == 0 then
			return true
		end
		local relation = tokens[index].value:match("^%s*(.-)%s*$") or ""
		if relation == ">" then
			return candidate.parent ~= nil and matchAt(index - 1, candidate.parent)
		elseif relation == "+" then
			local sibling = previous(candidate, observe)
			return sibling ~= nil and matchAt(index - 1, sibling)
		elseif relation == "~" then
			local sibling = previous(candidate, observe)
			while sibling do
				if matchAt(index - 1, sibling) then
					return true
				end
				sibling = previous(sibling, observe)
			end
		else
			local ancestor = candidate.parent
			while ancestor do
				if matchAt(index - 1, ancestor) then
					return true
				end
				ancestor = ancestor.parent
			end
		end
		return false
	end
	return #tokens > 0 and matchAt(#tokens, node)
end

function Selectors.matches(tokens: { Token }, node: Node, scope: Node, observe: Observer?): boolean
	return matches(tokens, node, scope, observe, false)
end

-- Prepared roots supply a read-only dependency observer. The ordinary matcher
-- retains its existing visit order for direct callers and mutable observers.
function Selectors.matchesPrepared(tokens: { Token }, node: Node, scope: Node, observe: Observer?): boolean
	return matches(tokens, node, scope, observe, true)
end

-- Prove that matching cannot read the tree. Hover/active include descendants
-- in this matcher, so they deliberately keep the ordinary observation path.
function Selectors.localInputs(tokens: { Token }): boolean
	for _, token in tokens do
		if anchors[token.kind] or token.kind == "universal" or token.kind == "comment" then
			continue
		end
		if token.kind ~= "pseudo" then
			return false
		end
		local value = token.value
		if value == ":is" or value == ":where" or value == ":not" then
			for _, branch in token.children or {} do
				if branch.kind ~= "selector" or not Selectors.localInputs(branch.children or {}) then
					return false
				end
			end
		elseif
			not states[value]
			or states[value] == "hover"
			or states[value] == "active"
			or value == ":focus-within"
		then
			return false
		end
	end
	return true
end
return Selectors
