--!strict

local Types = require(script.Parent.Types)
local Whitespace = require(script.Parent.Whitespace)
local TextContent = require(script.Parent.TextContent)
local TextLine = require(script.Parent.TextLine)
local TextParagraph = require(script.Parent.TextParagraph)
local TextBreaks = require(script.Parent.TextBreaks)
local FlexTypes = require(script.Parent.FlexTypes)

export type Result = { minimum: number, maximum: number, measure: FlexTypes.Measure }
local TextIntrinsic = {}

-- Supported wrapping text: measure every legal fragment for min-content and
-- suppress soft wrapping for max-content. Native shaping owns each fragment's
-- complete advance; independently measured character widths are never summed.
function TextIntrinsic.resolve(
	node: Types.Node,
	style: Types.ComputedStyle,
	atoms: { Whitespace.Atom },
	context: TextLine.Context
): (Result?, string?)
	local maximumContext = table.clone(context)
	maximumContext.width = 0
	maximumContext.selectedLine = true
	local maximum: number = 0
	local pending = false
	local minimum: number = 0
	local segment: { Whitespace.Atom } = {}
	local work, copied, paragraphs = 0, 0, 0
	local function append(forced: boolean): string?
		if forced or #segment > 0 then
			paragraphs += 1
			if paragraphs > 1024 then
				return "text-paragraph-line-budget-provider-required"
			end
		end
		local breaks, failure = TextBreaks.resolve(style, segment)
		if not breaks then
			return failure
		end
		local wholeContext = table.clone(maximumContext)
		wholeContext.ending = if forced then "forced" else "end"
		local whole, wholeFailure = TextLine.resolve(node, style, segment, wholeContext)
		if wholeFailure == "pending-text-measurement" then
			pending = true
		elseif not whole then
			return wholeFailure
		else
			maximum = math.max(maximum, whole.advance)
		end
		local first = 1
		for _, last in breaks.intrinsic do
			work += 1
			copied += last - first + 1
			if work > 2048 or copied > 1000000 then
				return "text-intrinsic-work-budget-provider-required"
			end
			local fragment: { Whitespace.Atom } = {}
			for index = first, last do
				table.insert(fragment, breaks.active[index])
			end
			local fragmentContext = table.clone(maximumContext)
			fragmentContext.ending = if last < #breaks.active then "soft" elseif forced then "forced" else "end"
			local line, lineFailure = TextLine.resolve(node, style, fragment, fragmentContext)
			if lineFailure == "pending-text-measurement" then
				pending = true
			elseif not line then
				return lineFailure
			else
				minimum = math.max(minimum, line.advance)
			end
			first = last + 1
		end
		table.clear(segment)
		return nil
	end
	for _, atom in atoms do
		if atom.discarded then
			continue
		elseif atom.kind == "break" then
			if
				atom.text ~= "\n"
				and not (TextContent.isUnicodeForcedBreak(atom.codepoint) and atom.text == utf8.char(atom.codepoint))
			then
				return nil, "text-paragraph-break-provider-required"
			end
			local failure = append(true)
			if failure then
				return nil, failure
			end
		else
			table.insert(segment, atom)
		end
	end
	local failure = append(false)
	if failure then
		return nil, failure
	elseif pending then
		return nil, "pending-text-measurement"
	end
	if minimum > maximum then
		return nil, "text-intrinsic-nonmonotonic-widths-provider-required"
	end
	return {
		minimum = minimum,
		maximum = maximum,
		measure = function(constraints: FlexTypes.Constraints): (FlexTypes.Size?, string?)
			if
				constraints.widthMode ~= "exactly"
				or constraints.width == nil
				or constraints.heightMode ~= "undefined"
			then
				return nil, "text-intrinsic-measurement-constraints-required"
			end
			local actual = table.clone(context)
			actual.width = constraints.width
			actual.selectedLine = nil
			local paragraph, reason = TextParagraph.resolve(node, style, atoms, actual)
			if not paragraph then
				return nil, reason
			end
			return { width = constraints.width, height = paragraph.height }, nil
		end,
	},
		nil
end

return TextIntrinsic
