--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local PositionValues = require(script.Parent.PositionValues)

export type Context = {
	width: number,
	height: number?,
	direction: string,
	lengths: Measurements.Context,
}
export type Offset = { x: number, y: number }

local RelativePosition = {}

local function word(tokens: { Types.ValueToken }?): string?
	return if tokens and #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

local inset = PositionValues.inset

-- The caller supplies physical properties and the containing block's direction.
-- Offsets are paint translations; they never change normal-flow geometry.
function RelativePosition.resolve(style: Types.ComputedStyle, context: Context): (Offset?, string?)
	if style.unresolved.position then
		return nil, `position:{style.unresolved.position}`
	end
	local position = word(style.properties.position) or (if not style.properties.position then "static" else nil)
	if position == "static" then
		return { x = 0, y = 0 }, nil
	end
	if position ~= "relative" then
		return nil, `positioning-provider-required:{position or "invalid"}`
	end
	if context.direction ~= "ltr" and context.direction ~= "rtl" then
		return nil, "relative-position-containing-direction-required"
	end
	local values: { [string]: number? } = {}
	for _, side in { "top", "right", "bottom", "left" } do
		local basis = if side == "left" or side == "right" then context.width else context.height
		local value, failure = inset(style, side, basis, context.lengths)
		if failure then
			return nil, failure
		end
		values[side] = value
	end
	local left, right, top, bottom = values.left, values.right, values.top, values.bottom
	local x = if context.direction == "rtl" and right ~= nil then -right elseif left ~= nil then left else -(right or 0)
	local y = if top ~= nil then top else -(bottom or 0)
	return { x = x, y = y }, nil
end

return RelativePosition
