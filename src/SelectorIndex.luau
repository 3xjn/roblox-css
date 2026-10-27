--!strict

local Types = require(script.Parent.Types)

local function anchor(tokens: { Types.SelectorToken }): (string?, string?)
	local start = 1
	for index, token in tokens do
		if token.kind == "combinator" then
			start = index + 1
		end
	end
	local kind: string? = nil
	local value: string? = nil
	for index = start, #tokens do
		local token = tokens[index]
		-- Only direct, required tokens in the subject compound are anchors.
		-- Prefer a direct requirement to an alternative set from a function.
		if token.kind == "id" then
			return "ids", token.value
		end
		if token.kind == "class" then
			kind, value = "classes", token.value
		elseif not kind and token.kind == "tag" then
			kind, value = "tags", string.lower(token.value)
		end
	end
	return kind, value
end

type Anchor = { kind: string, value: string }

local alternatives: ({ Types.SelectorToken }) -> { Anchor }?
alternatives = function(tokens: { Types.SelectorToken }): { Anchor }?
	local kind, value = anchor(tokens)
	if kind and value then
		return { { kind = kind, value = value } }
	end
	local start = 1
	for index, token in tokens do
		if token.kind == "combinator" then
			start = index + 1
		end
	end
	for index = start, #tokens do
		local token = tokens[index]
		if token.kind ~= "pseudo" or (token.value ~= ":is" and token.value ~= ":where") then
			continue
		end
		local result: { Anchor } = {}
		local complete = token.children ~= nil and #token.children > 0
		for _, branch in token.children or {} do
			local anchors = if branch.kind == "selector" and branch.children then alternatives(branch.children) else nil
			if not anchors then
				complete = false
				break
			end
			for _, item in anchors do
				table.insert(result, item)
			end
		end
		-- Every possible branch must require an anchor on the subject. Negation,
		-- relational selectors and a branch such as '*' retain the broad path.
		if complete then
			return result
		end
	end
	return nil
end

local function add(buckets: Types.SelectorBuckets, index: number, kind: string?, value: string?)
	local bucket = buckets.universal
	if kind and value then
		local map = if kind == "ids" then buckets.ids elseif kind == "classes" then buckets.classes else buckets.tags
		if not map[value] then
			map[value] = {}
		end
		bucket = map[value]
	end
	-- Selectors from one rule can share a bucket. Rules arrive in source
	-- order, so duplicate references for this rule are adjacent there.
	if bucket[#bucket] ~= index then
		table.insert(bucket, index)
	end
end

local SelectorIndex = {}

function SelectorIndex.create(rules: { Types.PreparedRule }): Types.SelectorIndex
	local result: Types.SelectorIndex = { targets = {}, declarationOffsets = {} }
	local declarations = 0
	for index, rule in rules do
		result.declarationOffsets[index] = declarations
		declarations += #rule.declarations
		for _, selector in rule.selectors do
			local target = selector.pseudoElement or ""
			local buckets = result.targets[target]
			if not buckets then
				buckets = { universal = {}, ids = {}, classes = {}, tags = {} }
				result.targets[target] = buckets
			end
			local kind, value = anchor(selector.tokens)
			local choices = if kind then nil else alternatives(selector.tokens)
			if choices then
				for _, item in choices do
					add(buckets, index, item.kind, item.value)
				end
			else
				add(buckets, index, kind, value)
			end
		end
	end
	return result
end

function SelectorIndex.candidates(index: Types.SelectorIndex, node: Types.Node, target: string?): { number }
	local buckets = index.targets[target or ""]
	if not buckets then
		return {}
	end
	local result = {}
	local seen: { [number]: boolean } = {}
	local function add(bucket: { number }?)
		for _, rule in bucket or {} do
			if not seen[rule] then
				seen[rule] = true
				table.insert(result, rule)
			end
		end
	end
	add(buckets.universal)
	add(buckets.tags[string.lower(node.tag)])
	if node.id then
		add(buckets.ids[node.id])
	end
	for name, present in node.classes do
		if present then
			add(buckets.classes[name])
		end
	end
	table.sort(result)
	return result
end

return SelectorIndex
