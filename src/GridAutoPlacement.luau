--!strict

local GridPlacement = require(script.Parent.GridPlacement)
local WorkQueue = require(script.Parent.WorkQueue)

export type Item = { row: GridPlacement.Axis, column: GridPlacement.Axis, order: number? }
export type Area = { rowStart: number, rowEnd: number, columnStart: number, columnEnd: number }
export type Context = {
	rows: number,
	columns: number,
	flow: ("row" | "column")?,
	dense: boolean?,
	maximumTracks: number?,
}
export type Result = {
	areas: { Area },
	order: { number },
	rowStart: number,
	rowEnd: number,
	columnStart: number,
	columnEnd: number,
}
type Ranked = { index: number, order: number, major: GridPlacement.Axis, minor: GridPlacement.Axis }
type Rect = { first: number, last: number, start: number, finish: number }

local GridAutoPlacement = {}
local maximumInteger = 9007199254740991

local function integer(value: number): boolean
	return value == value and math.abs(value) <= maximumInteger and value % 1 == 0
end

local function valid(axis: GridPlacement.Axis): boolean
	if not integer(axis.span) or axis.span < 1 then
		return false
	end
	if axis.start == nil and axis.finish == nil then
		return true
	end
	return axis.start ~= nil
		and axis.finish ~= nil
		and integer(axis.start)
		and integer(axis.finish)
		and axis.finish > axis.start
		and axis.finish - axis.start == axis.span
end

-- Logical coordinates; column flow transposes the same algorithm. Occupancy
-- is a list of rectangles, avoiding an allocation for every covered cell.
-- The caller supplies resolved lines/spans and retains logical child order.
function GridAutoPlacement.resolve(items: { Item }, context: Context): (Result?, string?)
	local budget = context.maximumTracks or 4096
	if
		not integer(budget)
		or budget < 1
		or not integer(context.rows)
		or not integer(context.columns)
		or context.rows < 0
		or context.columns < 0
		or context.rows > budget
		or context.columns > budget
	then
		return nil, "invalid-grid-placement-context"
	end
	if context.flow ~= nil and context.flow ~= "row" and context.flow ~= "column" then
		return nil, "invalid-grid-auto-flow"
	end
	local transpose = context.flow == "column"
	local majorStart, minorStart = 1, 1
	local majorEnd = (if transpose then context.columns else context.rows) + 1
	local minorEnd = (if transpose then context.rows else context.columns) + 1
	local ranked: { Ranked } = {}
	for index, item in items do
		WorkQueue.checkpoint()
		if not valid(item.row) or not valid(item.column) or not integer(item.order or 0) then
			return nil, "invalid-grid-placement-item"
		end
		if item.row.span > budget or item.column.span > budget then
			return nil, "grid-track-budget-exceeded"
		end
		table.insert(ranked, {
			index = index,
			order = item.order or 0,
			major = if transpose then item.column else item.row,
			minor = if transpose then item.row else item.column,
		})
	end
	table.sort(ranked, function(a: Ranked, b: Ranked)
		return if a.order == b.order then a.index < b.index else a.order < b.order
	end)
	local occupied: { Rect } = {}
	local locked: { Rect } = {}
	local placed: { [number]: Rect } = {}
	local function bounded(): boolean
		return majorEnd - majorStart <= budget and minorEnd - minorStart <= budget
	end
	local function reserve(item: Ranked, major: number, minor: number): boolean
		local rect = { first = major, last = major + item.major.span, start = minor, finish = minor + item.minor.span }
		majorStart, majorEnd = math.min(majorStart, rect.first), math.max(majorEnd, rect.last)
		minorStart, minorEnd = math.min(minorStart, rect.start), math.max(minorEnd, rect.finish)
		if not bounded() then
			return false
		end
		table.insert(occupied, rect)
		placed[item.index] = rect
		return true
	end
	-- Return the first possible coordinate past all current collisions. Moving
	-- within one of these rectangles cannot open a valid position, so this is a
	-- jump over occupied intervals rather than a cell-by-cell search.
	local function collision(major: number, minor: number, majorSpan: number, minorSpan: number): (number?, number?)
		local nextMinor, nextMajor: number? = nil, nil
		for _, rect in occupied do
			WorkQueue.checkpoint()
			if
				major < rect.last
				and major + majorSpan > rect.first
				and minor < rect.finish
				and minor + minorSpan > rect.start
			then
				nextMinor = math.max(nextMinor or rect.finish, rect.finish)
				nextMajor = math.max(nextMajor or rect.last, rect.last)
			end
		end
		return nextMinor, nextMajor
	end
	-- Definite items may intentionally overlap each other.
	for _, item in ranked do
		if item.major.start ~= nil and item.minor.start ~= nil then
			if not reserve(item, item.major.start, item.minor.start) then
				return nil, "grid-track-budget-exceeded"
			end
		end
	end
	-- Locked-major items are placed before determining implicit minor tracks.
	for _, item in ranked do
		if placed[item.index] or item.major.start == nil then
			continue
		end
		local major, minor = item.major.start, 1
		if not context.dense then
			for _, rect in locked do
				if major < rect.last and major + item.major.span > rect.first then
					minor = math.max(minor, rect.finish)
				end
			end
		end
		while true do
			WorkQueue.checkpoint()
			local nextMinor = collision(major, minor, item.major.span, item.minor.span)
			if not nextMinor then
				break
			end
			minor = nextMinor
			if minor + item.minor.span - minorStart > budget then
				return nil, "grid-track-budget-exceeded"
			end
		end
		if not reserve(item, major, minor) then
			return nil, "grid-track-budget-exceeded"
		end
		table.insert(locked, placed[item.index])
	end
	local maximumSpan = 0
	for _, item in ranked do
		if item.minor.start ~= nil then
			minorStart = math.min(minorStart, item.minor.start)
			minorEnd = math.max(minorEnd, assert(item.minor.finish))
		else
			maximumSpan = math.max(maximumSpan, item.minor.span)
		end
	end
	minorEnd = math.max(minorEnd, minorStart + maximumSpan)
	if not bounded() then
		return nil, "grid-track-budget-exceeded"
	end
	local major, minor = majorStart, minorStart
	for _, item in ranked do
		if placed[item.index] then
			continue
		end
		if context.dense then
			major, minor = majorStart, minorStart
		end
		if item.minor.start ~= nil then
			local column = item.minor.start
			if not context.dense and column < minor then
				major += 1
			end
			minor = column
			while true do
				WorkQueue.checkpoint()
				local _, nextMajor = collision(major, minor, item.major.span, item.minor.span)
				if not nextMajor then
					break
				end
				major = nextMajor
				if major + item.major.span - majorStart > budget then
					return nil, "grid-track-budget-exceeded"
				end
			end
		else
			while true do
				WorkQueue.checkpoint()
				if minor + item.minor.span > minorEnd then
					major, minor = major + 1, minorStart
				else
					local nextMinor = collision(major, minor, item.major.span, item.minor.span)
					if not nextMinor then
						break
					end
					minor = nextMinor
				end
				if major + item.major.span - majorStart > budget then
					return nil, "grid-track-budget-exceeded"
				end
			end
		end
		if not reserve(item, major, minor) then
			return nil, "grid-track-budget-exceeded"
		end
	end
	local areas: { Area } = {}
	local order = {}
	for _, item in ranked do
		local rect = placed[item.index]
		areas[item.index] = {
			rowStart = if transpose then rect.start else rect.first,
			rowEnd = if transpose then rect.finish else rect.last,
			columnStart = if transpose then rect.first else rect.start,
			columnEnd = if transpose then rect.last else rect.finish,
		}
		table.insert(order, item.index)
	end
	return {
		areas = areas,
		order = order,
		rowStart = if transpose then minorStart else majorStart,
		rowEnd = if transpose then minorEnd else majorEnd,
		columnStart = if transpose then majorStart else minorStart,
		columnEnd = if transpose then majorEnd else minorEnd,
	},
		nil
end

return GridAutoPlacement
