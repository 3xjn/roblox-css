--!strict

local Unicode = require(script.Parent.Parent.Unicode)
local Types = require(script.Parent.Types)
local Whitespace = require(script.Parent.Whitespace)
local LogicalProperties = require(script.Parent.LogicalProperties)

export type Opportunities = { active: { Whitespace.Atom }, candidates: { number }, emergency: { number }, intrinsic: { number } }
local TextBreaks = {}

local function policy(style: Types.ComputedStyle, name: string, initial: string): string?
	if style.unresolved[name] then
		return `{name}:{style.unresolved[name]}`
	end
	local tokens = style.properties[name]
	if tokens and (#tokens ~= 1 or tokens[1].kind ~= "word" or string.lower(tokens[1].value) ~= initial) then
		return `text-wrap-policy-provider-required:{name}`
	end
	return nil
end

-- Shared Unicode/whitespace boundaries for layout and intrinsic sizing.
-- Forced paragraph breaks are split by the paragraph owner before this call.
function TextBreaks.resolve(style: Types.ComputedStyle, atoms: { Whitespace.Atom }): (Opportunities?, string?)
	local physical, mappingFailure = LogicalProperties.view(style)
	if not physical then
		return nil, mappingFailure
	end
	style = physical
	local defaults: { [string]: string } = {
		["word-break"] = "normal",
		["line-break"] = "auto",
		hyphens = "manual",
	}
	for name, initial in defaults do
		local failure = policy(style, name, initial)
		if failure then
			return nil, failure
		end
	end
	local wrapFailure = policy(style, "overflow-wrap", "normal")
	local wrapTokens = style.properties["overflow-wrap"]
	local wrap = if wrapTokens and #wrapTokens == 1 and wrapTokens[1].kind == "word" then string.lower(wrapTokens[1].value) else "normal"
	if wrapFailure and (style.unresolved["overflow-wrap"] or (wrap ~= "anywhere" and wrap ~= "break-word")) then
		return nil, wrapFailure
	end
	local active: { Whitespace.Atom } = {}
	local pieces: { string } = {}
	local offsets: { [number]: number } = {}
	local bytes = 0
	for _, atom in atoms do
		if atom.discarded then
			continue
		end
		-- Balance and pretty are optional line-selection improvements. Use the
		-- normal wrapping algorithm when an optimizing formatter is unavailable.
		if atom.policy.wrap == "wrap" and not Whitespace.usesNormalWrapping(atom.policy.wrapStyle) then
			return nil, `text-wrap-style-provider-required:{atom.policy.wrapStyle}`
		end
		local atomWrap = atom.policy.overflowWrap or wrap
		if atomWrap ~= "normal" and atomWrap ~= "anywhere" and atomWrap ~= "break-word" then
			return nil, "text-wrap-policy-provider-required:overflow-wrap"
		end
		if
			atom.policy.collapse ~= "collapse"
			and atom.policy.collapse ~= "preserve-breaks"
			and atom.policy.collapse ~= "break-spaces"
		then
			return nil, "text-wrap-preserved-hanging-provider-required"
		end
		if atom.codepoint == 0xAD then
			return nil, "text-wrap-discretionary-hyphen-provider-required"
		end
		local class = Unicode.lineBreakProperty(atom.codepoint)
		if class == "SA" then
			return nil, "text-wrap-dictionary-provider-required"
		end
		table.insert(active, atom)
		table.insert(pieces, atom.text)
		bytes += #atom.text
		offsets[bytes] = #active
	end
	if #active == 0 then
		return { active = {}, candidates = {}, emergency = {}, intrinsic = {} }, nil
	end
	local breaks, breakFailure = Unicode.lineBreaks(table.concat(pieces))
	if not breaks then
		return nil, breakFailure
	end
	local allowed: { [number]: boolean } = {}
	for _, boundary in breaks do
		local index = offsets[boundary.position]
		if not index then
			return nil, "text-wrap-transformed-atom-boundary-provider-required"
		end
		if boundary.required and index ~= #active then
			return nil, "text-wrap-unprocessed-mandatory-break"
		end
		-- The terminal boundary is needed even when the final run is nowrap.
		-- Within a nowrap run, Unicode opportunities are not soft breaks.
		if index == #active or active[index].policy.wrap == "wrap" then
			allowed[index] = true
		end
	end
	for index, atom in active do
		if atom.policy.wrap == "wrap" and atom.policy.collapse == "break-spaces" and atom.kind == "space" then
			allowed[index] = true
		end
	end
	local candidates: { number } = {}
	for index in active do
		if allowed[index] then
			table.insert(candidates, index)
		end
	end
	local emergency: { number } = {}
	local intrinsicSet = table.clone(allowed)
	-- Emergency boundaries must not split a grapheme cluster, including across spans.
	for _, lastByte in utf8.graphemes(table.concat(pieces)) do
		local index = offsets[lastByte]
		if index and index < #active then
			local atom = active[index]
			local overflow = atom.policy.overflowWrap or wrap
			if atom.policy.wrap == "wrap" and (overflow == "anywhere" or overflow == "break-word") then
				table.insert(emergency, index)
				if overflow == "anywhere" then intrinsicSet[index] = true end
			end
		end
	end
	local intrinsic: { number } = {}
	for index in active do
		if intrinsicSet[index] then table.insert(intrinsic, index) end
	end
	return { active = active, candidates = candidates, emergency = emergency, intrinsic = intrinsic }, nil
end

return TextBreaks
