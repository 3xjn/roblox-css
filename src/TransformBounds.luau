--!strict

type Rect = { x: number, y: number, width: number, height: number }
local TransformBounds = {}

-- Bounds relative to the native frame's unshifted position. UIScale scales the
-- frame from its top-left; Rotation then pivots around that scaled center.
function TransformBounds.resolve(rect: Rect, width: number, height: number, rotation: number, scale: number): Rect
	if rotation == 0 and scale == 1 then
		return rect
	end
	local angle = rotation % 360
	local s, c = math.sin(math.rad(angle)), math.cos(math.rad(angle))
	if angle == 0 then
		s, c = 0, 1
	elseif angle == 90 then
		s, c = 1, 0
	elseif angle == 180 then
		s, c = 0, -1
	elseif angle == 270 then
		s, c = -1, 0
	end
	local halfX, halfY = width / 2, height / 2
	local centerX, centerY = rect.x + rect.width / 2 - halfX, rect.y + rect.height / 2 - halfY
	local x, y = scale * (halfX + c * centerX - s * centerY), scale * (halfY + s * centerX + c * centerY)
	local extentX = scale * (math.abs(c) * rect.width + math.abs(s) * rect.height)
	local extentY = scale * (math.abs(s) * rect.width + math.abs(c) * rect.height)
	return { x = x - extentX / 2, y = y - extentY / 2, width = extentX, height = extentY }
end

return TransformBounds
