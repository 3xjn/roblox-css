--!strict

local Types = require(script.Parent.Types)
local LayoutStyles = {}

-- ScenePreparation consumes these again without changing box/glyph geometry.
local paint: { [string]: boolean } = {
	color = true,
	opacity = true,
	["pointer-events"] = true,
	["background-color"] = true,
	["box-shadow"] = true,
	["outline-color"] = true,
	["border-top-color"] = true,
	["border-right-color"] = true,
	["border-bottom-color"] = true,
	["border-left-color"] = true,
	["text-decoration-color"] = true,
}

local function sameTokens(a: { Types.ValueToken }?, b: { Types.ValueToken }?): boolean
	if a == b then
		return true
	end
	if not a or not b or #a ~= #b then
		return false
	end
	for i, token in a do
		local other = b[i]
		if
			token.kind ~= other.kind
			or token.value ~= other.value
			or token.unit ~= other.unit
			or token.quote ~= other.quote
			or token.syntaxType ~= other.syntaxType
		then
			return false
		end
		local ca, cb = token.color, other.color
		if ca ~= cb and (not ca or not cb or ca.r ~= cb.r or ca.g ~= cb.g or ca.b ~= cb.b or ca.alpha ~= cb.alpha) then
			return false
		end
		if not sameTokens(token.children, other.children) then
			return false
		end
	end
	return true
end

local function sameArray(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for i, value in a do
		if b[i] ~= value then
			return false
		end
	end
	return true
end

local function samePriority(a: Types.Priority?, b: Types.Priority?): boolean
	if a == b then
		return true
	end
	return a ~= nil
		and b ~= nil
		and a.important == b.important
		and a.inline == b.inline
		and a.order == b.order
		and a.logical == b.logical
		and sameArray(a.layer, b.layer)
		and sameArray(a.specificity, b.specificity)
end

local function presentation(name: string, intrinsic: boolean?): boolean
	-- Selection policy cannot affect intrinsic sizes. This does not promise
	-- that a particular native text-editing backend implements that policy.
	return paint[name] == true or intrinsic == true and (name == "user-select" or name == "-webkit-user-select")
end

local function same(a: Types.ComputedStyle?, b: Types.ComputedStyle?, intrinsic: boolean?): boolean
	if a == b then
		return true
	end
	if not a or not b then
		return false
	end
	for name, reason in a.unresolved do
		if b.unresolved[name] ~= reason then
			return false
		end
	end
	for name in b.unresolved do
		if a.unresolved[name] == nil then
			return false
		end
	end
	for name, tokens in a.properties do
		if not presentation(name, intrinsic) and not sameTokens(tokens, b.properties[name]) then
			return false
		end
	end
	for name, tokens in b.properties do
		if not presentation(name, intrinsic) and not sameTokens(tokens, a.properties[name]) then
			return false
		end
	end
	if intrinsic then
		-- Unmapped logical/physical candidates still depend on cascade priority.
		-- Custom-property priorities cannot choose physical longhands; their
		-- resolved values are already represented by the consuming tokens above.
		for name, priority in a.priorities do
			if
				name:sub(1, 2) ~= "--"
				and not presentation(name, true)
				and not samePriority(priority, b.priorities[name])
			then
				return false
			end
		end
		for name, priority in b.priorities do
			if
				name:sub(1, 2) ~= "--"
				and not presentation(name, true)
				and not samePriority(priority, a.priorities[name])
			then
				return false
			end
		end
	end
	return true
end

-- Preserve SceneCache's existing conservative scene-layout comparison.
function LayoutStyles.same(a: Types.ComputedStyle?, b: Types.ComputedStyle?): boolean
	return same(a, b, false)
end

-- Only the built-in intrinsic formatter opts into this read-only contract.
function LayoutStyles.sameIntrinsic(a: Types.ComputedStyle?, b: Types.ComputedStyle?): boolean
	return same(a, b, true)
end

return LayoutStyles
