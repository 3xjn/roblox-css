--!strict

local Types = require(script.Parent.Types)
local SceneTypes = require(script.Parent.SceneTypes)
local TextLine = require(script.Parent.TextLine)
local TextWrap = require(script.Parent.TextWrap)
local Typography = require(script.Parent.Typography)
local Whitespace = require(script.Parent.Whitespace)
local TextContent = require(script.Parent.TextContent)

export type Result = {
	advance: number,
	height: number,
	lineCount: number,
	baselines: SceneTypes.Baselines?,
	runs: { SceneTypes.GlyphRun },
}
local TextParagraph = {}

-- Paragraph assembly owns line boundaries and block extent; TextLine retains
-- native shaping, CSS line metrics, alignment and baseline-provider policy.
-- TextWrap selects Unicode opportunities using whole-line shaping, not TextWrapped.
function TextParagraph.resolve(
	node: Types.Node,
	style: Types.ComputedStyle,
	atoms: { Whitespace.Atom },
	context: TextLine.Context
): (Result?, string?)
	if #node.children > 0 then
		return nil, "mixed-inline-content-provider-required"
	end
	local result: Result = { advance = 0, height = 0, lineCount = 0, runs = {} }
	local lineAtoms: { Whitespace.Atom } = {}
	local function append(forced: boolean): string?
		local lineContext = table.clone(context)
		lineContext.ending = if forced then "forced" else "end"
		local lines, failure = TextWrap.resolve(node, style, lineAtoms, lineContext)
		if not lines then
			return failure
		end
		for _, line in lines do
			local height = line.height
			local contributes = #line.runs > 0 or forced
			if contributes and #line.runs == 0 then
				-- A preserved newline contributes a strut even when all preceding
				-- spaces collapse. The empty tail after the final newline does not.
				local strut = Typography.lineHeight(style, context.fontMetrics)
				if not strut or strut ~= strut or strut < 0 or math.abs(strut) == math.huge then
					return "text-paragraph-computed-line-height-required"
				end
				height = strut
			end
			if contributes then
				result.lineCount += 1
				if result.lineCount > 1024 then
					return "text-paragraph-line-budget-provider-required"
				end
				local baseline = if line.baseline ~= nil then result.height + line.baseline else nil
				if baseline ~= nil and (baseline ~= baseline or math.abs(baseline) == math.huge) then
					return "text-paragraph-baseline-overflow"
				end
				if result.lineCount == 1 then
					result.baselines = { first = baseline, last = baseline }
				else
					local baselines = assert(result.baselines)
					baselines.last = baseline
				end
				for index, run in line.runs do
					local placed = table.clone(run)
					placed.key = `line:{result.lineCount}:{tostring(run.key or index)}`
					placed.y += result.height
					table.insert(result.runs, placed)
				end
				result.height += height
				result.advance = math.max(result.advance, line.advance)
				if result.height ~= result.height or math.abs(result.height) == math.huge then
					return "text-paragraph-geometry-overflow"
				end
			end
		end
		table.clear(lineAtoms)
		return nil
	end
	for _, atom in atoms do
		if atom.discarded then
			continue
		end
		if atom.source ~= node then
			return nil, "mixed-inline-text-source-provider-required"
		end
		if atom.kind == "break" then
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
			table.insert(lineAtoms, atom)
		end
	end
	local failure = append(false)
	return if failure then nil else result, failure
end

return TextParagraph
