--!strict

local Types = require(script.Parent.Types)
local Whitespace = require(script.Parent.Whitespace)
local TextLine = require(script.Parent.TextLine)

local TextBreaks = require(script.Parent.TextBreaks)

local TextWrap = {}

-- Choose lines from explicit Unicode opportunities. Each candidate is shaped
-- as a complete line; widths are never summed or assumed to be monotonic.
function TextWrap.resolve(
	node: Types.Node,
	style: Types.ComputedStyle,
	atoms: { Whitespace.Atom },
	context: TextLine.Context
): ({ TextLine.Result }?, string?)
	local whole, wholeFailure = TextLine.resolve(node, style, atoms, context)
	if whole then
		return { whole }, nil
	elseif wholeFailure ~= "text-line-wrapping-provider-required" then
		return nil, wholeFailure
	end
	local opportunities, breakFailure = TextBreaks.resolve(style, atoms)
	if not opportunities then
		return nil, breakFailure
	end
	local active, candidates = opportunities.active, opportunities.candidates
	local result: { TextLine.Result } = {}
	local first, work, copied = 1, 0, 0
	while first <= #active do
		local chosen: TextLine.Result? = nil
		local chosenEnd: number? = nil
		local fallback: TextLine.Result? = nil
		local fallbackEnd: number? = nil
		local pending = false
		local candidateSet: { [number]: boolean } = {}
		for _, last in candidates do candidateSet[last] = true end
		local allCandidates = table.clone(candidates)
		for _, last in opportunities.emergency do
			if not candidateSet[last] then table.insert(allCandidates, last) end
		end
		table.sort(allCandidates)
		local emergencyLine: TextLine.Result? = nil
		local emergencyEnd: number? = nil
		for _, last in allCandidates do
			if last < first then
				continue
			end
			work += 1
			if work > 2048 then
				return nil, "text-wrap-measurement-budget-provider-required"
			end
			copied += last - first + 1
			if copied > 1000000 then
				return nil, "text-wrap-atom-work-budget-provider-required"
			end
			local slice: { Whitespace.Atom } = {}
			for index = first, last do
				table.insert(slice, active[index])
			end
			local lineContext = table.clone(context)
			lineContext.selectedLine = true
			lineContext.ending = if last == #active then context.ending or "end" else "soft"
			local line, failure = TextLine.resolve(node, style, slice, lineContext)
			if not line then
				if failure == "pending-text-measurement" then
					-- Submit the remaining candidates to the existing bounded cache
					-- in this pass. Choose no boundary until every candidate is ready.
					pending = true
					continue
				end
				return nil, failure
			end
			if candidateSet[last] then
				if not fallback then fallback, fallbackEnd = line, last end
				if line.advance <= context.width then chosen, chosenEnd = line, last end
			elseif (fallbackEnd == nil or last < fallbackEnd) and line.advance <= context.width then
				emergencyLine, emergencyEnd = line, last
			end
		end
		if pending then
			return nil, "pending-text-measurement"
		end
		-- No legal fragment fits: CSS normal wrapping lets the first unbreakable
		-- fragment overflow, rather than inventing an emergency character break.
		local line, last = chosen or emergencyLine or fallback, chosenEnd or emergencyEnd or fallbackEnd
		if not line or not last then
			return nil, "text-wrap-no-progress-boundary"
		end
		table.insert(result, line)
		if #result > 1024 then
			return nil, "text-paragraph-line-budget-provider-required"
		end
		first = last + 1
	end
	return result, nil
end

return TextWrap
