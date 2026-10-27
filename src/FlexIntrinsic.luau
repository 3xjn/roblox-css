--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local FlexTypes = require(script.Parent.FlexTypes)
local FlexSizing = require(script.Parent.FlexSizing)
local Display = require(script.Parent.Display)

export type Entry = {
	item: FlexTypes.Item,
	-- CSS Sizing contributions, constrained by the item's preferred/min/max
	-- width, in border-box pixels excluding its margins.
	minimum: number,
	maximum: number,
}
export type Widths = { minimum: number, maximum: number }

local FlexIntrinsic = {}
local columnDefaults: { [string]: string } = { ["writing-mode"] = "horizontal-tb", ["flex-wrap"] = "nowrap" }

local function word(style: Types.ComputedStyle, property: string, initial: string): (string?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local tokens = style.properties[property]
	if not tokens then
		return initial, nil
	end
	if #tokens == 1 and tokens[1].kind == "word" then
		return string.lower(tokens[1].value), nil
	end
	return nil, `intrinsic-flex-value-required:{property}`
end

-- Single-line inline contributions. Rows share the ordinary flex
-- frontend so factors, content bases and automatic minima have one owner.
-- Browser compatibility rationale and pinned engine references are documented
-- in docs/flex-layout.md; the spec's ideal flex fractions are not used here.
function FlexIntrinsic.resolve(
	style: Types.ComputedStyle,
	entries: { Entry },
	lengths: Measurements.Context
): (Widths?, string?)
	local items: { FlexTypes.Item } = {}
	for _, entry in entries do
		if
			entry.minimum < 0
			or entry.maximum < entry.minimum
			or entry.minimum ~= entry.minimum
			or entry.maximum >= math.huge
			or entry.maximum ~= entry.maximum
		then
			return nil, "invalid-flex-intrinsic-contribution"
		end
		table.insert(items, entry.item)
	end
	local flow, flowFailure = word(style, "flex-direction", "row")
	if not flow then
		return nil, flowFailure
	end
	if flow == "column" or flow == "column-reverse" then
		-- Width is the cross axis: main-axis flex bases/factors and vertical
		-- gaps do not enter the largest child's width contribution.
		local display, displayFailure = Display.resolve(style)
		if display ~= "flex" and display ~= "inline-flex" then
			return nil, displayFailure or "flex-container-required"
		end
		for property, initial in columnDefaults do
			local value, failure = word(style, property, initial)
			if value ~= initial then
				return nil, failure or `intrinsic-flex-provider-required:{property}`
			end
		end
		local minimum: number = 0
		local maximum: number = 0
		for _, entry in entries do
			local visibility, failure = word(entry.item.style, "visibility", "visible")
			if not visibility or visibility == "collapse" then
				return nil, failure or "collapsed-flex-strut-provider-required"
			end
			local margin = entry.item.metrics.margin.left.value + entry.item.metrics.margin.right.value
			local low, high = entry.minimum + margin, entry.maximum + margin
			if low ~= low or high ~= high or math.abs(low) >= math.huge or math.abs(high) >= math.huge then
				return nil, "flex-intrinsic-width-overflow"
			end
			minimum = math.max(minimum, low)
			maximum = math.max(maximum, high)
		end
		return { minimum = minimum, maximum = math.max(minimum, maximum) }, nil
	end
	local wrap, wrapFailure = word(style, "flex-wrap", "nowrap")
	if not wrap then
		return nil, wrapFailure
	end
	local sizingStyle = style
	if wrap == "wrap" or wrap == "wrap-reverse" then
		sizingStyle = table.clone(style)
		sizingStyle.properties = table.clone(style.properties)
		sizingStyle.properties["flex-wrap"] = { { kind = "word", value = "nowrap" } }
	end
	local prepared, failure = FlexSizing.prepare(sizingStyle, items, {
		width = 0,
		height = 0,
		widthDefinite = false,
		heightDefinite = false,
		autoHeight = true,
		lengths = lengths,
	})
	if not prepared then
		return nil, failure
	end
	if prepared.flow ~= "row" and prepared.flow ~= "row-reverse" then
		return nil, "intrinsic-flex-column-width-provider-required"
	end
	local minimum: number = 0
	local maximum: number = 0
	local wrappedMinimum: number = 0
	for index, item in prepared.items do
		local entry = entries[index]
		local base = item.basis or item.width or item.flexBase
		if base == nil then
			return nil, "measured-flex-base-required"
		end
		local definiteBasis = item.basis ~= nil or item.width ~= nil
		local hypothetical =
			math.max(item.metrics.horizontalInset, item.minWidth, math.min(base, item.maxWidth or math.huge))
		local function contribution(value: number): number
			local cannotFlex = (value > base and item.grow == 0) or (value < base and item.shrink == 0)
			return if definiteBasis and cannotFlex then hypothetical else value
		end
		local margin = item.metrics.margin.left.value + item.metrics.margin.right.value
		wrappedMinimum = math.max(wrappedMinimum, entry.minimum + margin)
		minimum += contribution(entry.minimum) + margin
		maximum += contribution(entry.maximum) + margin
	end
	local gaps = math.max(0, #entries - 1) * prepared.gap
	if math.abs(minimum) >= math.huge or math.abs(maximum) >= math.huge or gaps >= math.huge then
		return nil, "flex-intrinsic-width-overflow"
	end
	minimum = if wrap == "wrap" or wrap == "wrap-reverse" then wrappedMinimum else math.max(0, minimum + gaps)
	maximum = math.max(minimum, maximum + gaps)
	if minimum ~= minimum or maximum ~= maximum or maximum >= math.huge then
		return nil, "flex-intrinsic-width-overflow"
	end
	return { minimum = minimum, maximum = maximum }, nil
end

return FlexIntrinsic
