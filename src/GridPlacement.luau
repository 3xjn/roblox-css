--!strict

local Types = require(script.Parent.Types)
local GridLine = require(script.Parent.GridLine)
local WorkQueue = require(script.Parent.WorkQueue)
local Measurements = require(script.Parent.Measurements)

local GridPlacement = {}
export type Context = { tracks: number, names: { [string]: { number } }?, lengths: Measurements.Context? }
export type Axis = { start: number?, finish: number?, span: number }
local maximumInteger = 9007199254740991

local function integer(value: number): boolean
	return value == value and math.abs(value) <= maximumInteger and value % 1 == 0
end

-- Explicit names index lines, not tracks. Repeated names on one line count
-- once. Copy before sorting: neither caller context nor computed CSS is owned.
local function named(context: Context, name: string): ({ number }?, string?)
	local result: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, value in if context.names then context.names[name] or {} else {} do
		WorkQueue.checkpoint()
		if not integer(value) or value < 1 or value > context.tracks + 1 then
			return nil, "grid-explicit-line-model-required"
		end
		if not seen[value] then
			seen[value] = true
			table.insert(result, value)
		end
	end
	table.sort(result)
	return result, nil
end

local function line(value: GridLine.Line, ending: boolean, context: Context): (number?, string?)
	if not value.name then
		local index = assert(value.index)
		return if index > 0 then index else context.tracks + 1 + (index + 1), nil
	end
	if value.index == nil then
		local area, failure = named(context, value.name .. (if ending then "-end" else "-start"))
		if not area then
			return nil, failure
		elseif #area > 0 then
			return area[1], nil
		end
	end
	local lines, failure = named(context, value.name)
	if not lines then
		return nil, failure
	end
	local index = value.index or 1
	if index > 0 then
		return if lines[index] then lines[index] else context.tracks + 1 + (index - #lines), nil
	end
	local position = #lines + 1 + index
	return if position > 0 then lines[position] else position, nil
end

local function span(from: number, value: GridLine.Line, direction: number, context: Context): (number?, string?)
	local remaining = value.index or 1
	if not value.name then
		return from + direction * remaining, nil
	end
	local lines, failure = named(context, value.name)
	if not lines then
		return nil, failure
	end
	if direction > 0 then
		for _, position in lines do
			if position > from then
				remaining -= 1
				if remaining == 0 then
					return position, nil
				end
			end
		end
		return math.max(from, context.tracks + 1) + remaining, nil
	end
	for i = #lines, 1, -1 do
		local position = lines[i]
		if position < from then
			remaining -= 1
			if remaining == 0 then
				return position, nil
			end
		end
	end
	return math.min(from, 1) - remaining, nil
end

-- Pure line-based placement before the grid's automatic-placement phase.
-- Coordinates can extend before/after the explicit grid; do not clamp them
-- to existing tracks or confuse negative indices with negative line positions.
function GridPlacement.axis(start: GridLine.Line, finish: GridLine.Line, context: Context): (Axis?, string?)
	if not integer(context.tracks) or context.tracks < 0 or context.tracks >= maximumInteger then
		return nil, "grid-explicit-track-count-required"
	end
	local first, last: number? = nil, nil
	local failure: string? = nil
	if start.kind == "line" then
		first, failure = line(start, false, context)
		if not first then
			return nil, failure
		end
	end
	if finish.kind == "line" then
		last, failure = line(finish, true, context)
		if not last then
			return nil, failure
		end
	end
	if first and last then
		if first > last then
			first, last = last, first
		elseif first == last then
			last = first + 1
		end
	elseif first then
		last, failure = span(first, if finish.kind == "span" then finish else { kind = "span", index = 1 }, 1, context)
	elseif last then
		first, failure = span(last, if start.kind == "span" then start else { kind = "span", index = 1 }, -1, context)
	else
		local value = if start.kind == "span" then start elseif finish.kind == "span" then finish else nil
		return { span = if value and not value.name then value.index or 1 else 1 }, nil
	end
	if failure or not first or not last then
		return nil, failure or "grid-line-resolution-required"
	end
	local resolvedFirst, resolvedLast = assert(first), assert(last)
	if not integer(resolvedFirst) or not integer(resolvedLast) or not integer(resolvedLast - resolvedFirst) then
		return nil, "grid-line-integer-range-provider-required"
	end
	return { start = resolvedFirst, finish = resolvedLast, span = resolvedLast - resolvedFirst }, nil
end

function GridPlacement.resolve(style: Types.ComputedStyle, axis: "row" | "column", context: Context): (Axis?, string?)
	local start, finish = `grid-{axis}-start`, `grid-{axis}-end`
	if style.unresolved[start] or style.unresolved[finish] then
		return nil, style.unresolved[start] or style.unresolved[finish]
	end
	local a, aFailure =
		GridLine.parse(style.properties[start] or { { kind = "word", value = "auto" } }, context.lengths)
	local b, bFailure =
		GridLine.parse(style.properties[finish] or { { kind = "word", value = "auto" } }, context.lengths)
	if not a or not b then
		return nil, aFailure or bFailure
	end
	return GridPlacement.axis(a, b, context)
end

return GridPlacement
