--!strict

-- A margin strut retains both extrema. Collapsing a collapsed numeric margin
-- again would lose information when positive and negative margins coexist.
export type Strut = { positive: number, negative: number }
export type Child = {
	height: number,
	top: Strut,
	bottom: Strut,
	through: boolean,
	-- For an empty box's own position, exclude its own bottom margin from the
	-- otherwise adjoining group (CSS 2.2 section 8.3.1).
	beforeBottom: Strut,
}
export type Options = {
	marginTop: number,
	marginBottom: number,
	collapseTop: boolean,
	collapseBottom: boolean,
	canCollapseThrough: boolean,
	minimumContentHeight: number,
}
export type Result = {
	contentHeight: number,
	positions: { number },
	top: Strut,
	bottom: Strut,
	through: boolean,
	beforeBottom: Strut,
}

local BlockFlow = {}

function BlockFlow.margin(value: number): Strut
	return { positive = math.max(0, value), negative = math.min(0, value) }
end

function BlockFlow.merge(a: Strut, b: Strut): Strut
	return { positive = math.max(a.positive, b.positive), negative = math.min(a.negative, b.negative) }
end

function BlockFlow.value(strut: Strut): number
	return strut.positive + strut.negative
end

function BlockFlow.resolve(children: { Child }, options: Options): Result
	local top, bottom = BlockFlow.margin(options.marginTop), BlockFlow.margin(options.marginBottom)
	local pending = BlockFlow.margin(0)
	local positions: { number } = {}
	local cursor = 0
	local hasSeparatedChild = false
	for index, child in children do
		if child.through then
			local beforeBottom = BlockFlow.merge(pending, child.beforeBottom)
			positions[index] = if not hasSeparatedChild and options.collapseTop
				then 0
				else cursor + BlockFlow.value(beforeBottom)
			pending = BlockFlow.merge(pending, child.top)
		else
			pending = BlockFlow.merge(pending, child.top)
			if not hasSeparatedChild and options.collapseTop then
				top = BlockFlow.merge(top, pending)
			else
				cursor += BlockFlow.value(pending)
			end
			positions[index] = cursor
			cursor += child.height
			pending = child.bottom
			hasSeparatedChild = true
		end
	end
	local through = options.canCollapseThrough and not hasSeparatedChild
	local beforeBottom = top
	if not hasSeparatedChild and options.collapseTop then
		top = BlockFlow.merge(top, pending)
		beforeBottom = top
	end
	if through then
		local joined = BlockFlow.merge(top, bottom)
		return {
			contentHeight = 0,
			positions = positions,
			top = joined,
			bottom = joined,
			through = true,
			beforeBottom = beforeBottom,
		}
	end
	-- A positive min-height separates an all-through children's margin group
	-- from the parent's bottom when that group already adjoins its top.
	local topAbsorbed = not hasSeparatedChild and options.collapseTop
	local collapseBottom = options.collapseBottom and not (topAbsorbed and options.minimumContentHeight > 0)
	if collapseBottom then
		bottom = BlockFlow.merge(bottom, pending)
	elseif not topAbsorbed then
		cursor += BlockFlow.value(pending)
	end
	return {
		contentHeight = math.max(0, cursor),
		positions = positions,
		top = top,
		bottom = bottom,
		through = false,
		beforeBottom = beforeBottom,
	}
end

return BlockFlow
