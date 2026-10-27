--!strict

local Types = require(script.Parent.Types)
local BoxModel = require(script.Parent.BoxModel)
local BoxChildren = require(script.Parent.BoxChildren)
local Display = require(script.Parent.Display)
local Measurements = require(script.Parent.Measurements)
local SizingValue = require(script.Parent.SizingValue)
local AspectRatio = require(script.Parent.AspectRatio)
local FlexScene = require(script.Parent.FlexScene)
local FlexTypes = require(script.Parent.FlexTypes)
local GridTracks = require(script.Parent.GridTracks)
local GridTrackSizing = require(script.Parent.GridTrackSizing)
local GridIntrinsicSizing = require(script.Parent.GridIntrinsicSizing)
local SceneTypes = require(script.Parent.SceneTypes)

export type Item = {
	node: Types.Node,
	style: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	lengths: Measurements.Context,
	raw: FlexScene.Intrinsic,
	minimumWidth: number,
	maximumWidth: number,
}
export type Axis = {
	definitions: { GridTracks.Track },
	initial: { GridTrackSizing.Track },
	first: number,
	last: number,
	gap: number,
	trackBasis: number?,
	basis: number?,
	minimum: number,
	maximum: number,
}
export type Sizes = {
	preferred: number?,
	minimum: number,
	maximum: number,
	minContent: number,
	maxContent: number,
	contribution: number,
}

local GridItems = {}

local function isReplaced(node: Types.Node): boolean
	return node.tag == "img" or node.tag == "input" or node.tag == "textarea"
end

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

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
	return nil, `grid-item-value-provider-required:{property}`
end

local function empty(node: Types.Node, snapshot: SceneTypes.Snapshot): (boolean?, string?)
	if node.text ~= "" then
		return false, nil
	end
	local children, failure = BoxChildren.resolve(node, snapshot)
	if not children then
		return nil, failure
	end
	for _, child in children do
		local style = snapshot.styles[child]
		if not style then
			return nil, "missing-grid-item-child-style"
		end
		local display, displayFailure = Display.resolve(style)
		if not display then
			return nil, displayFailure
		end
		local position, positionFailure = word(style, "position", "static")
		if not position then
			return nil, positionFailure
		end
		if display ~= "none" and position ~= "absolute" and position ~= "fixed" then
			return false, nil
		end
	end
	return true, nil
end

function GridItems.prepare(
	node: Types.Node,
	style: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	lengths: Measurements.Context,
	snapshot: SceneTypes.Snapshot,
	provider: FlexScene.Provider
): (Item?, string?)
	local ratio, ratioFailure = AspectRatio.resolve(style, metrics)
	if ratioFailure or ratio then
		return nil, ratioFailure or "grid-item-aspect-ratio-provider-required"
	end
	local provided, failure = provider({
		node = node,
		style = style,
		metrics = metrics,
		lengths = lengths,
		snapshot = snapshot,
		width = 0,
		widthDefinite = false,
		flow = "row",
		inlineSizeRequired = true,
	})
	if failure then
		return nil, failure
	end
	local raw: FlexScene.Intrinsic = provided or {}
	local low, high = raw.minContentWidth, raw.maxContentWidth
	if low == nil or high == nil then
		local preferred, sizeFailure =
			SizingValue.resolve(style, "width", metrics, lengths, nil, metrics.horizontalInset)
		if sizeFailure then
			return nil, sizeFailure
		end
		local isEmpty, emptyFailure = empty(node, snapshot)
		if emptyFailure then
			return nil, emptyFailure
		end
		if preferred ~= nil then
			low, high = preferred + metrics.horizontalInset, preferred + metrics.horizontalInset
		elseif isEmpty or isReplaced(node) then
			low, high = metrics.horizontalInset, metrics.horizontalInset
		else
			return nil, "grid-item-intrinsic-width-provider-required"
		end
	end
	local minimumWidth, maximumWidth = assert(low), assert(high)
	if
		not finite(minimumWidth)
		or not finite(maximumWidth)
		or minimumWidth < metrics.horizontalInset
		or maximumWidth < minimumWidth
	then
		return nil, "invalid-grid-item-inline-contributions"
	end
	return {
		node = node,
		style = style,
		metrics = metrics,
		lengths = lengths,
		raw = raw,
		minimumWidth = minimumWidth,
		maximumWidth = maximumWidth,
	},
		nil
end

local function automatic(
	item: Item,
	axis: Axis,
	preferred: number?,
	maximum: number,
	inset: number,
	margins: number
): (number?, string?)
	for _, name in { "overflow-x", "overflow-y" } do
		local value, failure = word(item.style, name, "visible")
		if not value then
			return nil, failure
		end
		if value == "hidden" or value == "auto" or value == "scroll" then
			return inset, nil
		end
		if value ~= "visible" and value ~= "clip" then
			return nil, "grid-item-overflow-provider-required"
		end
	end
	local auto, flexible, allFixed = false, false, true
	local maximumArea = axis.gap * (axis.last - axis.first)
	for index = axis.first, axis.last do
		local definition, state = axis.definitions[index], axis.initial[index]
		local minimum = definition.minimum
		auto = auto
			or minimum.kind == "auto"
			or (
				minimum.kind == "length"
				and axis.trackBasis == nil
				and Measurements.hasPercentage(minimum.tokens or {})
			)
		flexible = flexible or state.flex ~= nil
		if definition.maximum.kind == "length" and not state.stretchable then
			maximumArea += state.limit
		else
			allFixed = false
		end
	end
	if not auto or (axis.last > axis.first and flexible) then
		return inset, nil
	end
	local suggestion = math.min(preferred or axis.minimum, maximum)
	if allFixed then
		suggestion = math.min(suggestion, math.max(inset, maximumArea - margins))
	end
	return math.max(inset, suggestion), nil
end

-- Intrinsic quantities include the border box. Author dimensions are normalized
-- by the existing sizing resolver; margins are added once to outer contributions.
function GridItems.sizes(item: Item, horizontal: boolean, axis: Axis): (Sizes?, string?)
	local property = if horizontal then "width" else "height"
	local inset = if horizontal then item.metrics.horizontalInset else item.metrics.verticalInset
	local a, b = if horizontal then "left" else "top", if horizontal then "right" else "bottom"
	local margins = item.metrics.margin[a].value + item.metrics.margin[b].value
	local preferred, pFailure = SizingValue.resolve(item.style, property, item.metrics, item.lengths, axis.basis, inset)
	local minimum, minFailure =
		SizingValue.resolve(item.style, "min-" .. property, item.metrics, item.lengths, axis.basis, inset)
	local maximum, maxFailure =
		SizingValue.resolve(item.style, "max-" .. property, item.metrics, item.lengths, axis.basis, inset)
	if pFailure or minFailure or maxFailure then
		return nil, pFailure or minFailure or maxFailure
	end
	preferred = if preferred then preferred + inset else nil
	local upper = if maximum then maximum + inset else math.huge
	local lower = (minimum or 0) + inset
	local minName, nameFailure = word(item.style, "min-" .. property, "auto")
	-- A numeric minimum is already handled by SizingValue; only an unresolved
	-- non-numeric keyword needs the word diagnostic here.
	if minName == "auto" then
		local value, failure = automatic(item, axis, preferred, upper, inset, margins)
		if value == nil then
			return nil, failure
		end
		lower = math.max(lower, value)
	elseif item.style.unresolved["min-" .. property] then
		return nil, nameFailure
	end
	local function constrain(value: number): number
		return math.max(lower, math.min(value, upper))
	end
	local low = constrain(preferred or axis.minimum)
	local high = constrain(preferred or axis.maximum)
	return {
		preferred = preferred,
		minimum = lower,
		maximum = upper,
		minContent = low + margins,
		maxContent = high + margins,
		contribution = (if preferred then low else lower) + margins,
	},
		nil
end

function GridItems.contribution(sizes: Sizes, first: number, last: number): GridIntrinsicSizing.Contribution
	return {
		first = first,
		last = last,
		minimum = sizes.contribution,
		minContent = sizes.minContent,
		maxContent = sizes.maxContent,
	}
end

function GridItems.height(item: Item, width: number): (number?, string?)
	local replaced = isReplaced(item.node)
	if replaced then
		local height, failure =
			SizingValue.resolve(item.style, "height", item.metrics, item.lengths, nil, item.metrics.verticalInset)
		if failure then
			return nil, failure
		end
		if height ~= nil then
			return height + item.metrics.verticalInset, nil
		end
	end
	if item.raw.measure then
		local constraints: FlexTypes.Constraints = {
			width = math.max(0, width - item.metrics.horizontalInset),
			widthMode = "exactly",
			heightMode = "undefined",
		}
		local ok, result, failure = pcall(item.raw.measure, constraints)
		if not ok then
			return nil, `grid-item-measurement:{tostring(result)}`
		end
		if not result then
			if replaced and failure == "native-editor-intrinsic-height-provider-required" then
				return item.raw.minContentHeight or item.raw.hypotheticalCrossSize or item.metrics.verticalInset, nil
			end
			return nil, failure or "grid-item-height-measurement-required"
		end
		if not finite(result.width) or not finite(result.height) or result.height < 0 then
			return nil, "invalid-grid-item-height-measurement"
		end
		return result.height + item.metrics.verticalInset, nil
	end
	local height = item.raw.minContentHeight or item.raw.hypotheticalCrossSize
	if height == nil then
		local children = item.node.children
		if replaced or (item.node.text == "" and #children == 0) then
			height = item.metrics.verticalInset
		end
	end
	if height == nil then
		return nil, "grid-item-height-measurement-required"
	end
	if not finite(height) or height < item.metrics.verticalInset then
		return nil, "invalid-grid-item-height-contribution"
	end
	return height, nil
end

-- Placement owns outer margins/alignment; the item owns its border box. Used
-- assignments can be passed to the existing block/flex formatter unchanged.
function GridItems.place(
	item: Item,
	sizes: Sizes,
	horizontal: boolean,
	available: number,
	alignment: string,
	natural: number
): (number?, number?, string?)
	local a, b = if horizontal then "left" else "top", if horizontal then "right" else "bottom"
	if alignment == "normal" and isReplaced(item.node) then
		alignment = "start"
	end
	local first, last = item.metrics.margin[a], item.metrics.margin[b]
	local start, finish = first.value, last.value
	local size = sizes.preferred or natural
	if sizes.preferred == nil then
		if (alignment == "normal" or alignment == "stretch") and not first.auto and not last.auto then
			size = math.max(0, available - start - finish)
		elseif horizontal then
			size = math.max(
				sizes.minContent - start - finish,
				math.min(available - start - finish, sizes.maxContent - start - finish)
			)
		else
			size = natural
		end
	end
	size = math.max(sizes.minimum, math.min(size, sizes.maximum))
	local free = available - size - start - finish
	if (first.auto or last.auto) and free > 0 then
		local share = free / (if first.auto and last.auto then 2 else 1)
		return size, start + (if first.auto then share else 0), nil
	end
	if alignment == "normal" or alignment == "stretch" or alignment == "start" or alignment == "flex-start" then
		return size, start, nil
	end
	if alignment == "end" or alignment == "flex-end" then
		return size, start + free, nil
	end
	if alignment == "center" then
		return size, start + free / 2, nil
	end
	return nil, nil, `grid-item-alignment-provider-required:{alignment}`
end

return GridItems
