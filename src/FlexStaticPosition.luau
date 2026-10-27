--!strict

local Types = require(script.Parent.Types)
local BoxModel = require(script.Parent.BoxModel)
local ListLayout = require(script.Parent.ListLayout)

local FlexStaticPosition = {}

-- The flex static-position rectangle uses the container's content box and
-- the child's final used size, without flexing or other in-flow siblings.
-- Auto margins are zero for this hypothetical placement (Flexbox 4.1).
function FlexStaticPosition.resolve(
	parent: Types.ComputedStyle,
	child: Types.ComputedStyle,
	node: Types.Node,
	metrics: BoxModel.Metrics,
	width: number,
	height: number,
	context: ListLayout.Context
): ({ x: number, y: number }?, string?)
	local style = table.clone(child)
	style.properties = table.clone(child.properties)
	style.properties.position = { { kind = "word", value = "static" } }
	local fixed = table.clone(metrics)
	fixed.margin = table.clone(metrics.margin)
	for _, side in { "left", "right", "top", "bottom" } do
		local margin = metrics.margin[side]
		fixed.margin[side] = { value = if margin.auto then 0 else margin.value, auto = false }
	end
	local plan, failure = ListLayout.resolve(parent, {
		{ node = node, style = style, metrics = fixed, width = width, height = height },
	}, context)
	if not plan then
		return nil, failure
	end
	local offsets, offsetFailure = ListLayout.offsets(plan)
	if not offsets then
		return nil, offsetFailure
	end
	return offsets[node], nil
end

return FlexStaticPosition
