--!strict

local Whitespace = require(script.Parent.Whitespace)
local TextContent = require(script.Parent.TextContent)

export type HangingMode = "always" | "conditional"
export type Hanging = { [number]: HangingMode }
export type Ending = "soft" | "forced" | "end"

local LineWhitespace = {}

local function lineFailure(atoms: { Whitespace.Atom }): string?
	for _, atom in atoms do
		if not atom.discarded then
			if atom.kind == "break" or TextContent.hasHardBreak(atom.text) then
				return "line-boundaries-must-be-resolved"
			elseif atom.kind == "segment" then
				return "phase-one-whitespace-processing-required"
			end
		end
	end
	return nil
end

local function prepare(atoms: { Whitespace.Atom }): ({ Whitespace.Atom }?, string?)
	local failure = lineFailure(atoms)
	if failure then
		return nil, failure
	end
	local result: { Whitespace.Atom } = {}
	for _, atom in atoms do
		table.insert(result, table.clone(atom))
	end
	return result, nil
end

-- These edge operations preserve indices and source ranges, and do not mutate
-- paragraph atoms. The formatting provider supplies the appropriate line order;
-- these functions never perform or approximate Unicode bidi reordering.
function LineWhitespace.trimStart(atoms: { Whitespace.Atom }): ({ Whitespace.Atom }?, string?)
	local result, failure = prepare(atoms)
	if not result then
		return nil, failure
	end
	for _, atom in result do
		if atom.discarded or atom.kind == "bidi" then
			continue
		end
		if atom.kind == "space" and atom.collapsible then
			atom.discarded = true
		else
			break
		end
	end
	return result, nil
end

function LineWhitespace.trimEnd(atoms: { Whitespace.Atom }): ({ Whitespace.Atom }?, string?)
	local result, failure = prepare(atoms)
	if not result then
		return nil, failure
	end
	for index = #result, 1, -1 do
		local atom = result[index]
		if atom.discarded or atom.kind == "bidi" then
			continue
		end
		local ogham = atom.codepoint == 0x1680
			and (atom.policy.collapse == "collapse" or atom.policy.collapse == "preserve-breaks")
		if atom.kind == "space" and atom.collapsible or ogham then
			atom.discarded = true
		else
			break
		end
	end
	return result, nil
end

-- Unicode Zs other than U+0020 and U+00A0, as used by CSS's definition of
-- "other space separators" (Unicode 17.0 DerivedGeneralCategory.txt).
local function otherSeparator(codepoint: number): boolean
	return codepoint == 0x1680
		or codepoint >= 0x2000 and codepoint <= 0x200A
		or codepoint == 0x202F
		or codepoint == 0x205F
		or codepoint == 0x3000
end

-- Classify trailing white space after trimming and bidi reordering. Conditional
-- hanging is metadata: only the portion that does not fit hangs. A layout
-- provider must apply the classification using shaped advances and line width.
function LineWhitespace.classifyHanging(atoms: { Whitespace.Atom }, ending: Ending): (Hanging?, string?)
	if ending ~= "soft" and ending ~= "forced" and ending ~= "end" then
		return nil, "invalid-line-ending-kind"
	end
	local failure = lineFailure(atoms)
	if failure then
		return nil, failure
	end
	local result: Hanging = {}
	for index = #atoms, 1, -1 do
		local atom = atoms[index]
		if atom.discarded or atom.kind == "bidi" then
			continue
		end
		if atom.kind ~= "space" and atom.kind ~= "tab" and not otherSeparator(atom.codepoint) then
			break
		end
		local mode = atom.policy.collapse
		if mode == "collapse" or mode == "preserve-breaks" then
			if atom.kind == "space" and atom.collapsible or atom.codepoint == 0x1680 then
				return nil, "line-end-trimming-required"
			end
			result[index] = "always"
		elseif mode == "preserve" then
			if atom.policy.wrap ~= "nowrap" then
				result[index] = if ending == "soft" then "always" else "conditional"
			end
		elseif mode == "preserve-spaces" then
			return nil, "preserve-spaces-hanging-policy-required"
		elseif mode ~= "break-spaces" then
			return nil, `whitespace-hanging-provider-required:{mode}`
		end
	end
	return result, nil
end

return LineWhitespace
