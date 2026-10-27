--!strict

local ShadowPaint = require(script.Parent.ShadowPaint)

type Spec = {
	border: number,
	corners: { topLeft: number, topRight: number, bottomLeft: number, bottomRight: number }?,
	layers: { ShadowPaint.Shadow },
}
export type Plan = { bodyWidth: number, pixelWidth: number, center: Rect }

local ShadowSlice = {}
local scale = 2
ShadowSlice.sampleScale = scale

-- Bound every horizontal corner, clip edge and finite Gaussian support.
-- A shadow starts at inset + offset - spread. Its corner radius is no
-- greater than max(0, corner - inset + spread), even after normalization.
-- Their sum is offset + max(inset - spread, corner): spread is not paid
-- twice. The absolute-offset/max/blur bound is convex, so endpoint maxima
-- remain valid throughout bounded interpolation and reversal.
function ShadowSlice.edge(a: Spec, b: Spec?): number
	local edge = 0
	for _, spec in if b then { a, b } else { a } do
		local corner = 0
		for _, radius in spec.corners or {} do
			corner = math.max(corner, radius)
		end
		edge = math.max(edge, corner + spec.border)
		for _, layer in spec.layers do
			local inset = if layer.inset then spec.border else 0
			local spread = if layer.inset then -layer.spread else layer.spread
			local support = math.ceil(layer.blur * scale * 1.5) / scale
			edge = math.max(edge, math.abs(layer.x) + math.max(inset - spread, corner) + support + 1)
		end
	end
	return edge
end

function ShadowSlice.prepare(width: number, x: number, canvasWidth: number, pixelHeight: number, edge: number): Plan?
	for _, value in { width, x, canvasWidth, pixelHeight, edge } do
		if value ~= value or math.abs(value) == math.huge then
			return nil
		end
	end
	if pixelHeight < 4 then
		return nil
	end
	local band = math.ceil(edge * scale) / scale
	-- An integral logical cut preserves both edges' supersampling phase.
	-- Retain at least two logical pixels of constant center for filtering.
	local cut = math.floor(width - 2 * band - 2)
	if cut <= 0 then
		return nil
	end
	local bodyWidth = width - cut
	local pixelWidth = (canvasWidth - cut) * scale
	local left = math.ceil((band - x) * scale)
	local right = math.floor((bodyWidth - band - x) * scale)
	if left < 0 or right <= left or right > pixelWidth then
		return nil
	end
	-- Keep nonempty vertical edge slices. With unchanged height and half-scale
	-- borders they preserve the source sampling; a full-height center distorts
	-- EditableImage edges in the native renderer.
	local top = math.floor(pixelHeight / 2) - 1
	return { bodyWidth = bodyWidth, pixelWidth = pixelWidth, center = Rect.new(left, top, right, top + 2) }
end

return ShadowSlice
