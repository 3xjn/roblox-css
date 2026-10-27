--!strict

local Types = require(script.Parent.Types)
local TextContent = require(script.Parent.TextContent)

export type Source = Types.Node | string | number
export type Policy = { collapse: string, wrap: string, wrapStyle: string, overflowWrap: string? }
export type Span = { source: Source, text: string, policy: Policy }
export type Atom = {
	source: Source,
	spanIndex: number,
	firstByte: number,
	lastByte: number,
	codepoint: number,
	text: string,
	kind: string,
	policy: Policy,
	collapsible: boolean,
	discarded: boolean,
}
export type SegmentContext = { before: Atom?, after: Atom?, segment: Atom }
export type Options = { transformSegmentBreak: ((SegmentContext) -> (string?, string?))? }

local Whitespace = {}
local collapseValues: { [string]: boolean } = {
	collapse = true,
	preserve = true,
	["preserve-breaks"] = true,
	["preserve-spaces"] = true,
	["break-spaces"] = true,
}
local wrapStyles: { [string]: boolean } = {
	auto = true,
	balance = true,
	stable = true,
	pretty = true,
	["avoid-short-last-line"] = true,
}

-- These optimization hints can fall back to ordinary line selection.
function Whitespace.usesNormalWrapping(style: string): boolean
	return style == "auto" or style == "balance" or style == "pretty"
end

local function keyword(style: Types.ComputedStyle, property: string, initial: string): (string?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local name: string? = nil
	for _, token in style.properties[property] or {} do
		if token.kind == "space" or token.kind == "comment" then
			continue
		end
		if token.kind ~= "word" or name then
			return nil, `unsupported-whitespace-value:{property}`
		end
		name = string.lower(token.value)
	end
	return name or initial, nil
end

local function validate(policy: Policy): string?
	if not collapseValues[policy.collapse] then
		return `whitespace-collapse-provider-required:{policy.collapse}`
	end
	if policy.wrap ~= "wrap" and policy.wrap ~= "nowrap" then
		return "invalid-text-wrap-mode"
	end
	if not wrapStyles[policy.wrapStyle] then
		return `text-wrap-style-provider-required:{policy.wrapStyle}`
	end
	return nil
end

function Whitespace.resolve(style: Types.ComputedStyle): (Policy?, string?)
	local collapse, collapseFailure = keyword(style, "white-space-collapse", "collapse")
	local wrap, wrapFailure = keyword(style, "text-wrap-mode", "wrap")
	local wrapStyle, styleFailure = keyword(style, "text-wrap-style", "auto")
	local overflowWrap, overflowFailure = keyword(style, "overflow-wrap", "normal")
	local trim, trimFailure = keyword(style, "white-space-trim", "none")
	if not collapse or not wrap or not wrapStyle or not overflowWrap or not trim then
		return nil, collapseFailure or wrapFailure or styleFailure or overflowFailure or trimFailure
	end
	if trim ~= "none" then
		return nil, "whitespace-element-trimming-provider-required"
	end
	local policy: Policy = { collapse = collapse, wrap = wrap, wrapStyle = wrapStyle, overflowWrap = overflowWrap }
	local failure = validate(policy)
	return if failure then nil else policy, failure
end

local function bidiControl(codepoint: number): boolean
	return codepoint == 0x61C
		or codepoint == 0x200E
		or codepoint == 0x200F
		or codepoint >= 0x202A and codepoint <= 0x202E
		or codepoint >= 0x2066 and codepoint <= 0x2069
end

local function horizontal(atom: Atom): boolean
	return atom.kind == "space" or atom.kind == "tab"
end

-- Phase I only, over one complete inline formatting context in logical order.
-- Input is document text: HTML-style CRLF normalization belongs to its parser.
-- Discarded atoms retain their source range and any later break classification.
function Whitespace.process(spans: { Span }, options: Options?): ({ Atom }?, string?)
	local settings: Options = options or {}
	local atoms: { Atom } = {}
	for spanIndex, span in spans do
		local failure = validate(span.policy)
		if failure then
			return nil, failure
		end
		if not utf8.len(span.text) then
			return nil, "invalid-whitespace-text-utf8"
		end
		local policy = table.clone(span.policy)
		local collapsible = policy.collapse == "collapse" or policy.collapse == "preserve-breaks"
		for firstByte, codepoint in utf8.codes(span.text) do
			local character = utf8.char(codepoint)
			local kind = if codepoint == 10
				then "segment"
				elseif TextContent.isUnicodeForcedBreak(codepoint) then "break"
				elseif codepoint == 9 then "tab"
				elseif codepoint == 32 or codepoint == 13 then "space"
				elseif bidiControl(codepoint) then "bidi"
				else "character"
			table.insert(atoms, {
				source = span.source,
				spanIndex = spanIndex,
				firstByte = firstByte,
				lastByte = firstByte + #character - 1,
				codepoint = codepoint,
				text = if codepoint == 13 then " " else character,
				kind = kind,
				policy = policy,
				collapsible = collapsible
					and (kind == "space" or kind == "tab" or kind == "segment" and policy.collapse == "collapse"),
				discarded = false,
			})
		end
	end
	-- Remove collapsible horizontal whitespace adjoining a source segment break.
	for index, atom in atoms do
		if atom.kind ~= "segment" then
			continue
		end
		for _, direction in { -1, 1 } do
			local neighbor = index + direction
			while neighbor >= 1 and neighbor <= #atoms do
				local candidate = atoms[neighbor]
				if candidate.kind == "bidi" then
					neighbor += direction
				elseif horizontal(candidate) and candidate.collapsible then
					candidate.discarded = true
					neighbor += direction
				else
					break
				end
			end
		end
	end
	local previous: Atom? = nil
	local active: { Atom } = {}
	for _, atom in atoms do
		if atom.discarded or atom.kind == "bidi" then
			continue
		end
		if
			atom.kind == "segment"
			and atom.policy.collapse == "collapse"
			and previous
			and previous.kind == "segment"
			and previous.policy.collapse == "collapse"
		then
			atom.discarded = true
		else
			table.insert(active, atom)
			previous = atom
		end
	end
	-- Snapshot context before transformation, so a callback never sees a neighbor
	-- changed merely because its segment appeared earlier in the iteration.
	local replacements: { [Atom]: string } = {}
	for index, atom in active do
		if atom.kind == "segment" and atom.policy.collapse == "collapse" then
			local replacement: string? = " "
			local failure: string? = nil
			if settings.transformSegmentBreak then
				replacement, failure = settings.transformSegmentBreak({
					before = active[index - 1],
					after = active[index + 1],
					segment = atom,
				})
			end
			if replacement ~= " " and replacement ~= "" then
				return nil, failure or "invalid-segment-break-transformation"
			end
			replacements[atom] = replacement
		end
	end
	for _, atom in atoms do
		if atom.discarded then
			continue
		end
		if atom.kind == "segment" then
			if atom.policy.collapse == "collapse" then
				atom.text = replacements[atom]
				atom.kind = "space"
				atom.discarded = atom.text == ""
			elseif atom.policy.collapse == "preserve-spaces" then
				atom.text, atom.kind = " ", "space"
			else
				atom.kind = "break"
			end
		elseif atom.kind == "tab" and (atom.collapsible or atom.policy.collapse == "preserve-spaces") then
			atom.text, atom.kind = " ", "space"
		end
	end
	previous = nil
	for _, atom in atoms do
		if atom.discarded or atom.kind == "bidi" then
			continue
		end
		if
			atom.kind == "space"
			and atom.collapsible
			and previous
			and previous.kind == "space"
			and previous.collapsible
		then
			atom.discarded = true
		else
			previous = atom
		end
	end
	return atoms, nil
end

return Whitespace
