--!strict

local ScenePreparation = require(script.Parent.ScenePreparation)
local SceneTypes = require(script.Parent.SceneTypes)
local ListLayout = require(script.Parent.ListLayout)
local NativeShadow = require(script.Parent.NativeShadow)
local TransformBounds = require(script.Parent.TransformBounds)
local AnimationValues = require(script.Parent.AnimationValues)
export type Rect = { x: number, y: number, width: number, height: number }
local SceneBounds = {}
local function union(a: Rect, b: Rect): Rect
	local bx, by = b.x, b.y
	local left = math.min(a.x, bx)
	local top = math.min(a.y, by)
	return {
		x = left,
		y = top,
		width = math.max(a.x + a.width, bx + b.width) - left,
		height = math.max(a.y + a.height, by + b.height) - top,
	}
end
function SceneBounds.resolve(
	scene: ScenePreparation.Prepared,
	previous: (SceneTypes.Key) -> Rect?,
	transformBounds: ((SceneTypes.Key, Rect) -> (Rect?, string?))?
): ({ [SceneTypes.Key]: Rect }?, string?)
	local needed = false
	for _, box in scene.boxes do
		if box.opacitySurface then
			needed = true
			break
		end
	end
	if not needed then
		return {}, nil
	end
	local positions: { [SceneTypes.Key]: { x: number, y: number } } = {}
	local children: { [SceneTypes.Key]: { SceneTypes.Key } } = {}
	-- Only opacity surfaces and their render descendants contribute to a group.
	-- Preparation supplies parent-first order; an unrelated ancestor's position
	-- does not affect a surface's local ink bounds. The position index also marks
	-- membership, avoiding another retained cache or observer graph.
	for _, key in scene.order do
		local box = scene.boxes[key]
		local parent = box.source.parent
		if not box.opacitySurface and (parent == nil or positions[parent] == nil) then
			continue
		end
		positions[key] = { x = box.source.x + box.offsetX, y = box.source.y + box.offsetY }
	end
	-- Keep the original child union order: changing floating-point accumulation
	-- near an integer edge can change the final floor/ceil surface by a pixel.
	for key, box in scene.boxes do
		local parent = box.source.parent
		if positions[key] ~= nil and parent ~= nil and positions[parent] ~= nil then
			local list = children[parent] or {}
			children[parent] = list
			table.insert(list, key)
		end
	end
	for owner, list in scene.lists do
		if positions[owner] == nil then
			continue
		end
		local offsets, failure = ListLayout.offsets(list.plan)
		if not offsets then
			return nil, failure
		end
		for node, point in offsets do
			local key = list.views[node]
			local box = scene.boxes[key]
			positions[key] = { x = point.x + box.offsetX, y = point.y + box.offsetY }
		end
	end
	local bounds: { [SceneTypes.Key]: Rect } = {}
	for index = #scene.order, 1, -1 do
		local key = scene.order[index]
		if positions[key] == nil then
			continue
		end
		local box = scene.boxes[key]
		local g, paint = box.geometry, box.paint
		local rect: Rect = { x = 0, y = 0, width = g.width, height = g.height }
		for _, ring in paint.shadows or {} do
			rect = union(rect, {
				x = -ring.width,
				y = -ring.width,
				width = g.width + 2 * ring.width,
				height = g.height + 2 * ring.width,
			})
		end
		local outline = paint.outline
		if outline then
			local extent = math.max(0, outline.width + outline.offset)
			rect =
				union(rect, { x = -extent, y = -extent, width = g.width + 2 * extent, height = g.height + 2 * extent })
		end
		for _, shadow in paint.outerShadows or {} do
			rect = union(rect, shadow)
		end
		if paint.rasterShadows then
			local raster, failure = NativeShadow.prepare(paint.rasterShadows, g.width, g.height)
			if not raster then
				return nil, failure
			end
			rect = union(rect, raster)
		end
		-- A CSS transition can still be painting the preceding shadow outside the
		-- new target's ink bounds. Retain that owned envelope until a later commit.
		local old = previous(key)
		if old then
			rect = union(rect, old)
		end
		for _, run in box.source.runs or {} do
			rect =
				union(rect, { x = g.contentX + run.x, y = g.contentY + run.y, width = run.width, height = run.height })
		end
		for _, child in children[key] or {} do
			local childRect = bounds[child]
			local point = positions[child]
			local shifted: Rect = {
				x = g.contentX + point.x + childRect.x,
				y = g.contentY + point.y + childRect.y,
				width = childRect.width,
				height = childRect.height,
			}
			if paint.clip then
				local clip = paint.clipBox or { x = 0, y = 0, width = g.width, height = g.height }
				local left = math.max(shifted.x, clip.x)
				local top = math.max(shifted.y, clip.y)
				shifted = {
					x = left,
					y = top,
					width = math.max(0, math.min(shifted.x + shifted.width, clip.x + clip.width) - left),
					height = math.max(0, math.min(shifted.y + shifted.height, clip.y + clip.height) - top),
				}
			end
			rect = union(rect, shifted)
		end
		local translationBound = if box.animation then box.animation.bounds.translate else nil
		local transitionBounds: Rect? = nil
		if transformBounds then
			local value, why = transformBounds(key, rect)
			if why then
				return nil, why
			end
			transitionBounds = value
		end
		bounds[key] = transitionBounds
			or (
				if box.animationModel
					then AnimationValues.bounds(
						box.animationModel,
						rect,
						box.offsetX - (box.source.offsetX or 0),
						box.offsetY - (box.source.offsetY or 0),
						if type(translationBound) == "table" then translationBound else nil,
						if box.animation then box.animation.scaleRange else nil
					)
					else TransformBounds.resolve(rect, g.width, g.height, box.rotation or 0, box.scale or 1)
			)
	end
	local groups: { [SceneTypes.Key]: Rect } = {}
	for key, box in scene.boxes do
		if box.opacitySurface then
			local b = bounds[key]
			local x, y = math.floor(b.x) - 1, math.floor(b.y) - 1
			local width, height = math.ceil(b.x + b.width) + 1 - x, math.ceil(b.y + b.height) + 1 - y
			if width > 4096 or height > 4096 or width * height > 4194304 then
				return nil, "opacity-surface-budget-provider-required"
			end
			groups[key] = { x = x, y = y, width = width, height = height }
		end
	end
	return groups, nil
end
return SceneBounds
