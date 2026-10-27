--!strict
local Types = require(script.Parent.Types)
local SceneTypes = require(script.Parent.SceneTypes)
local Measurements = require(script.Parent.Measurements)
local Display = require(script.Parent.Display)
local PositionedPaintOrder = {}
-- Native Sibling collectors preserve each positioned stacking context.
function PositionedPaintOrder.apply(plan: SceneTypes.Plan, styles: { [Types.Node]: Types.ComputedStyle }): string?
	local stride = 1
	for _, box in plan.boxes do
		stride = math.max(stride, (box.zIndex or 0) + 1)
	end
	for _, box in plan.boxes do
		box.paintZIndex = nil
		local style = (plan.styles and plan.styles[box.node]) or styles[box.node]
		local tokens = style and style.properties["z-index"]
		if not style or not tokens or (#tokens == 1 and tokens[1].kind == "word" and tokens[1].value == "auto") then
			continue
		end
		local position = style.properties.position
		local positioned = position
			and #position == 1
			and position[1].kind == "word"
			and (position[1].value == "relative" or position[1].value == "absolute" or position[1].value == "fixed")
		local parent = box.parent and plan.boxes[box.parent]
		local parentStyle = parent and ((plan.styles and plan.styles[parent.node]) or styles[parent.node])
		local parentDisplay = parentStyle and Display.resolve(parentStyle)
		if not positioned and parentDisplay ~= "flex" and parentDisplay ~= "grid" then
			continue
		end
		local value, failure = Measurements.resolve(tokens, box.lengths)
		if not value or value.dimension ~= "number" or value.percentage ~= nil or value.value % 1 ~= 0 then
			return failure or "integer-z-index-provider-required"
		end
		if value.value < 0 and not box.outOfFlow then
			return "negative-stacking-context-provider-required"
		end
		local rank = value.value * stride + (box.zIndex or 0)
		if rank > 2147483647 or rank < -2147483648 then
			return "native-z-index-range-provider-required"
		end
		box.paintZIndex = rank
	end
	return nil
end
return PositionedPaintOrder
