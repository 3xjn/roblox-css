--!strict

local NativeColors = require(script.Parent.NativeColors)
local NativeDimensions = require(script.Parent.NativeDimensions)
local Transitions = require(script.Parent.Transitions)
local ShadowTransition = require(script.Parent.ShadowTransition)
local ShadowSlice = require(script.Parent.ShadowSlice)
local ShadowPaint = require(script.Parent.ShadowPaint)
local Profiler = require(script.Parent.Profiler)

export type Corners = ShadowTransition.Corners
export type Spec = ShadowTransition.Spec
export type Prepared = {
	x: number,
	y: number,
	width: number,
	height: number,
	pw: number,
	ph: number,
	key: string,
	slice: ShadowSlice.Plan?,
}
type Workspace = {
	count: number,
	red: { number },
	green: { number },
	blue: { number },
	alpha: { number },
	data: buffer,
}
type RasterLayer = { key: string, indices: { number }, values: { number } }
type RasterCache = {
	key: string,
	outerClip: { number },
	innerClip: { number },
	layers: { [number]: RasterLayer },
}
export type View = ShadowTransition.State<Prepared> & {
	bounds: Prepared?,
	cache: RasterCache?,
	label: ImageLabel,
	image: EditableImage?,
	sharedKey: string?,
	key: string?,
	workspace: Workspace?,
	rasterize: (View, Spec, Prepared, number, number) -> (buffer?, string?),
	upload: (EditableImage, Prepared, buffer) -> (),
}
local NativeShadow = {}
type SharedRaster = { image: EditableImage, references: number }
-- Only live, immutable rasters are shared. The last view releases the image;
-- inactive states and animation samples never accumulate in a global cache.
local sharedRasters: { [string]: SharedRaster } = {}
local available: boolean? = nil
local scale = ShadowSlice.sampleScale
local function finite(n: number): boolean
	return n == n and math.abs(n) < math.huge
end

local function supported(): boolean
	if available == nil then
		local probe: EditableImage? = nil
		local ok = pcall(function()
			probe = game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(1, 1) })
			assert(probe, "EditableImage allocation failed")
			assert(Content.fromObject(probe :: EditableImage))
		end)
		if probe then
			probe:Destroy()
		end
		available = ok
	end
	return available == true
end

local function rasterWork(spec: Spec, layer: ShadowPaint.Shadow): number
	if layer.color.alpha == 0 then
		return 0
	end
	if layer.blur == 0 then
		return 3
	end
	local corner = spec.border + math.abs(layer.spread)
	for _, radius in spec.corners or {} do
		corner = math.max(corner, radius + spec.border + math.abs(layer.spread))
	end
	-- Horizontal filtering uses rounded-row spans and the Gaussian CDF, not
	-- a second kernel convolution. Bound the antialiased corner spans plus
	-- their constant/interior/inverse runs; vertical filtering retains taps.
	local spans = 2 * (math.ceil(math.sqrt(2 * corner * scale)) + 2) + 5
	return 2 * math.ceil(layer.blur * scale * 1.5) + 1 + spans + 3
end

function NativeShadow.prepare(spec: Spec, width: number, height: number): (Prepared?, string?)
	if not supported() then
		return nil, "native-editable-shadow-unavailable"
	end
	if not finite(width) or not finite(height) or width < 0 or height < 0 then
		return nil, "invalid-raster-shadow-geometry"
	end
	if not finite(spec.border) or spec.border < 0 then
		return nil, "invalid-raster-shadow-border"
	end
	local left: number = -1
	local top: number = -1
	local right: number = width + 1
	local bottom: number = height + 1
	local key = { string.format("%.17g:%.17g:%.17g", width, height, spec.border) }
	local work = 0
	for _, radius in spec.corners or {} do
		if not finite(radius) or radius < 0 then
			return nil, "invalid-raster-shadow-corner"
		end
	end
	local corners = spec.corners
	table.insert(
		key,
		if corners
			then string.format(
				"%.17g:%.17g:%.17g:%.17g",
				corners.topLeft,
				corners.topRight,
				corners.bottomRight,
				corners.bottomLeft
			)
			else "square"
	)
	for _, layer in spec.layers do
		for _, n in
			{
				layer.x,
				layer.y,
				layer.blur,
				layer.spread,
				layer.color.r,
				layer.color.g,
				layer.color.b,
				layer.color.alpha,
			}
		do
			if not finite(n) then
				return nil, "invalid-raster-shadow-layer"
			end
		end
		if layer.blur < 0 then
			return nil, "invalid-raster-shadow-blur"
		end
		local margin = math.ceil(layer.blur * 1.5) + 1
		left = math.min(left, -margin)
		top = math.min(top, -margin)
		right = math.max(right, width + margin)
		bottom = math.max(bottom, height + margin)
		if not layer.inset and layer.color.alpha > 0 then
			left = math.min(left, layer.x - layer.spread - margin)
			top = math.min(top, layer.y - layer.spread - margin)
			right = math.max(right, width + layer.x + layer.spread + margin)
			bottom = math.max(bottom, height + layer.y + layer.spread + margin)
		end
		work += rasterWork(spec, layer)
		table.insert(
			key,
			string.format(
				"%.17g:%.17g:%.17g:%.17g:%s:%.17g:%.17g:%.17g:%.17g",
				layer.x,
				layer.y,
				layer.blur,
				layer.spread,
				tostring(layer.inset),
				layer.color.r,
				layer.color.g,
				layer.color.b,
				layer.color.alpha
			)
		)
	end
	left = math.floor(left)
	top = math.floor(top)
	right = math.ceil(right)
	bottom = math.ceil(bottom)
	local pw, ph = (right - left) * scale, (bottom - top) * scale
	local slice = ShadowSlice.prepare(width, left, right - left, ph, ShadowSlice.edge(spec))
	if slice then
		pw = slice.pixelWidth
	end
	if not finite(pw) or not finite(ph) or pw < 1 or ph < 1 or pw > 1024 or ph > 1024 or pw * ph * work > 16000000 then
		return nil, "raster-shadow-budget-provider-required"
	end
	return {
		x = left,
		y = top,
		width = right - left,
		height = bottom - top,
		pw = pw,
		ph = ph,
		key = table.concat(key, "|"),
		slice = slice,
	},
		nil
end

local function radii(corners: Corners?, inset: number, spread: number, width: number, height: number): { number }
	local result = {}
	local c = corners or { topLeft = 0, topRight = 0, bottomRight = 0, bottomLeft = 0 }
	for _, raw in { c.topLeft, c.topRight, c.bottomRight, c.bottomLeft } do
		local radius = math.max(0, raw - inset)
		local amount = spread
		if amount > 0 and radius < amount then
			amount *= 1 + (radius / amount - 1) ^ 3
		end
		table.insert(result, math.max(0, radius + amount))
	end
	local factor = 1
	for _, pair in
		{
			{ width, result[1] + result[2] },
			{ width, result[3] + result[4] },
			{ height, result[1] + result[4] },
			{ height, result[2] + result[3] },
		}
	do
		if pair[2] > 0 then
			factor = math.min(factor, math.max(0, pair[1]) / pair[2])
		end
	end
	for i, radius in result do
		result[i] = radius * factor
	end
	return result
end

local function inside(
	x: number,
	y: number,
	left: number,
	top: number,
	right: number,
	bottom: number,
	r: { number }
): number
	if
		right <= left
		or bottom <= top
		or x < left - 0.5 / scale
		or y < top - 0.5 / scale
		or x > right + 0.5 / scale
		or y > bottom + 0.5 / scale
	then
		return 0
	end
	local radius, cx, cy = 0, 0, 0
	if x < left + r[1] and y < top + r[1] then
		radius, cx, cy = r[1], left + r[1], top + r[1]
	elseif x > right - r[2] and y < top + r[2] then
		radius, cx, cy = r[2], right - r[2], top + r[2]
	elseif x > right - r[3] and y > bottom - r[3] then
		radius, cx, cy = r[3], right - r[3], bottom - r[3]
	elseif x < left + r[4] and y > bottom - r[4] then
		radius, cx, cy = r[4], left + r[4], bottom - r[4]
	end
	local distance = if radius == 0
		then math.min(x - left, right - x, y - top, bottom - y)
		else radius - math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2)
	-- Subpixel coverage prevents a moving edge from stepping between sample cells.
	return math.clamp(distance * scale + 0.5, 0, 1)
end

local function coverage(
	p: Prepared,
	left: number,
	top: number,
	right: number,
	bottom: number,
	r: { number },
	inverse: boolean
): { number }
	local result = table.create(p.pw * p.ph, if inverse then 1 else 0)
	if right <= left or bottom <= top then
		return result
	end
	local edge = 0.5 / scale
	local firstX = math.max(0, math.ceil((left - edge - p.x) * scale - 0.5))
	local lastX = math.min(p.pw - 1, math.floor((right + edge - p.x) * scale - 0.5))
	local firstY = math.max(0, math.ceil((top - edge - p.y) * scale - 0.5))
	local lastY = math.min(p.ph - 1, math.floor((bottom + edge - p.y) * scale - 0.5))
	for y = firstY, lastY do
		local py = p.y + (y + 0.5) / scale
		local leftRadius = if py < top + r[1] then r[1] elseif py > bottom - r[4] then r[4] else 0
		local rightRadius = if py < top + r[2] then r[2] elseif py > bottom - r[3] then r[3] else 0
		local firstCore = math.ceil((math.max(left + leftRadius, left + edge) - p.x) * scale - 0.5)
		local lastCore = math.floor((math.min(right - rightRadius, right - edge) - p.x) * scale - 0.5)
		local core = math.clamp(math.min(py - top, bottom - py) * scale + 0.5, 0, 1)
		local row = y * p.pw + 1
		for x = firstX, lastX do
			-- The row interior has constant coverage. Only the two curved/edge
			-- regions need the distance calculation (and its square root).
			local value = if x >= firstCore and x <= lastCore
				then core
				else inside(p.x + (x + 0.5) / scale, py, left, top, right, bottom, r)
			result[row + x] = if inverse then 1 - value else value
		end
	end
	return result
end

local function blur(values: { number }, width: number, height: number, sigma: number, clip: { number }): { number }
	if sigma == 0 then
		return values
	end
	local radius = math.ceil(sigma * 3)
	local kernel, total = {}, 0
	for offset = -radius, radius do
		local weight = math.exp(-offset ^ 2 / (2 * sigma ^ 2))
		kernel[offset + radius + 1] = weight
		total += weight
	end
	for index, weight in kernel do
		kernel[index] = weight / total
	end
	local prefix: { number } = { [0] = 0 }
	for index, weight in kernel do
		prefix[index] = prefix[index - 1] + weight
	end
	-- Both passes write the complete raster. Reserve their dense arrays once
	-- instead of growing them as each pixel is appended.
	local horizontal, result = table.create(width * height, 0), table.create(width * height, 0)
	-- Rounded-rectangle rows have constant spans and fractional edge coverage.
	-- Sum its contiguous spans through the Gaussian CDF instead of convolving
	-- the same interior pixel once per kernel tap.
	local spanStarts: { number } = {}
	local spanEnds: { number } = {}
	local spanValues: { number } = {}
	for y = 0, height - 1 do
		local spanCount = 0
		local first = 0
		local previous = 0
		for x = 0, width do
			local value = if x < width then values[y * width + x + 1] else 0
			if value ~= previous then
				if previous > 0 then
					spanCount += 1
					spanStarts[spanCount], spanEnds[spanCount], spanValues[spanCount] = first, x - 1, previous
				end
				first = x
				previous = value
			end
		end
		for x = 0, width - 1 do
			local sum = 0
			for index = 1, spanCount do
				local lo = math.max(-radius, spanStarts[index] - x)
				local hi = math.min(radius, spanEnds[index] - x)
				if lo <= hi then
					sum += (prefix[hi + radius + 1] - prefix[lo + radius]) * spanValues[index]
				end
			end
			horizontal[y * width + x + 1] = sum
		end
	end
	for y = 0, height - 1 do
		local firstOffset = math.max(-radius, -y)
		local lastOffset = math.min(radius, height - 1 - y)
		local firstRow = (y + firstOffset) * width + 1
		for x = 0, width - 1 do
			if clip[y * width + x + 1] == 0 then
				result[y * width + x + 1] = 0
				continue
			end
			local sum = 0
			local sample = firstRow + x
			for kernelIndex = firstOffset + radius + 1, lastOffset + radius + 1 do
				sum += horizontal[sample] * kernel[kernelIndex]
				sample += width
			end
			result[y * width + x + 1] = sum
		end
	end
	return result
end

local function pixels(view: View, spec: Spec, p: Prepared, width: number, height: number): (buffer?, string?)
	width = if p.slice then p.slice.bodyWidth else width
	local count = p.pw * p.ph
	local run = view.running
	local workspace = if run then view.workspace else nil
	if workspace and workspace.count == count then
		buffer.fill(workspace.data, 0, 0)
	end
	if not workspace or workspace.count ~= count then
		workspace = {
			count = count,
			red = table.create(count, 0),
			green = table.create(count, 0),
			blue = table.create(count, 0),
			alpha = table.create(count, 0),
			data = buffer.create(count * 4),
		}
		if run then
			view.workspace = workspace
		end
	end
	local scratch = assert(workspace)
	local red, green, blue, alpha = scratch.red, scratch.green, scratch.blue, scratch.alpha
	local outerR = radii(spec.corners, 0, 0, width, height)
	local border = spec.border
	local innerR = radii(spec.corners, border, 0, width - 2 * border, height - 2 * border)
	local key = string.format("%.17g:%.17g:%.17g:%.17g:%d:%d:%.17g", width, height, p.x, p.y, p.pw, p.ph, border)
		.. ":"
		.. table.concat(outerR, ":")
	local cache = view.cache
	if not cache or cache.key ~= key then
		local outerClip = coverage(p, 0, 0, width, height, outerR, true)
		local innerClip = coverage(p, border, border, width - border, height - border, innerR, false)
		cache = { key = key, outerClip = outerClip, innerClip = innerClip, layers = {} }
		view.cache = cache
	end
	local masks: RasterCache = assert(cache)

	for index = #spec.layers, 1, -1 do
		local layer = spec.layers[index]
		if layer.color.alpha == 0 then
			continue
		end
		local color, failure = NativeColors.fromRgba(layer.color)
		if not color then
			return nil, failure
		end
		local inset = if layer.inset then border else 0
		local spread = if layer.inset then -layer.spread else layer.spread
		local left, top = inset + layer.x - spread, inset + layer.y - spread
		local right, bottom = width - inset + layer.x + spread, height - inset + layer.y + spread
		local shapeR = radii(spec.corners, inset, spread, right - left, bottom - top)
		local clips = if layer.inset then masks.innerClip else masks.outerClip
		local maskKey = string.format(
			"%.17g:%.17g:%.17g:%.17g:%s",
			layer.x,
			layer.y,
			layer.blur,
			layer.spread,
			tostring(layer.inset)
		)
		local saved = masks.layers[index]
		local raster: RasterLayer
		if saved and saved.key == maskKey then
			raster = saved
		else
			local mask = coverage(p, left, top, right, bottom, shapeR, layer.inset)
			mask = blur(mask, p.pw, p.ph, layer.blur * scale / 2, clips)
			local indices, values = {}, {}
			for offset = 1, count do
				local value = math.clamp(mask[offset], 0, 1) * clips[offset]
				if value > 0 then
					table.insert(indices, offset)
					table.insert(values, value)
				end
			end
			raster = { key = maskKey, indices = indices, values = values }
			masks.layers[index] = raster
		end

		-- Geometry owns this sparse coverage. Color-only animation updates
		-- composite the affected samples without scanning transparent interiors.
		for sampleIndex, offset in raster.indices do
			local a = raster.values[sampleIndex] * (1 - color.transparency)
			red[offset] = color.value.R * a + red[offset] * (1 - a)
			green[offset] = color.value.G * a + green[offset] * (1 - a)
			blue[offset] = color.value.B * a + blue[offset] * (1 - a)
			alpha[offset] = a + alpha[offset] * (1 - a)
		end
	end
	local data = scratch.data
	for i = 1, count do
		local a = alpha[i]
		if a > 0 then
			buffer.writeu8(data, (i - 1) * 4, math.round(math.clamp(red[i] / a, 0, 1) * 255))
			buffer.writeu8(data, (i - 1) * 4 + 1, math.round(math.clamp(green[i] / a, 0, 1) * 255))
			buffer.writeu8(data, (i - 1) * 4 + 2, math.round(math.clamp(blue[i] / a, 0, 1) * 255))
			buffer.writeu8(data, (i - 1) * 4 + 3, math.round(math.clamp(a, 0, 1) * 255))
			if run then
				red[i], green[i], blue[i], alpha[i] = 0, 0, 0, 0
			end
		end
	end
	return data, nil
end

local function upload(image: EditableImage, p: Prepared, data: buffer)
	image:WritePixelsBuffer(Vector2.zero, Vector2.new(p.pw, p.ph), data)
end

local function release(image: EditableImage?, sharedKey: string?)
	if not image then
		return
	end
	if sharedKey then
		local entry = assert(sharedRasters[sharedKey])
		assert(entry.image == image and entry.references > 0)
		entry.references -= 1
		if entry.references > 0 then
			return
		end
		sharedRasters[sharedKey] = nil
	end
	image:Destroy()
end

local function write(
	view: View,
	spec: Spec,
	p: Prepared,
	width: number,
	height: number,
	share: boolean
): (boolean, string?)
	if view.key == p.key then
		return true, nil
	end
	local position, a = NativeDimensions.pair(p.x, p.y, Vector2.new(width, height))
	local size, b = NativeDimensions.pair(p.width, p.height, Vector2.new(width, height))
	if not position or not size then
		return false, a or b
	end
	local previous = view.image
	local entry = if share then sharedRasters[p.key] else nil
	local image: EditableImage? = if entry then entry.image else nil
	local reuse = false
	if not image then
		local data, failure = view.rasterize(view, spec, p, width, height)
		if not data then
			return false, failure
		end
		-- A shared texture is immutable, even when this view is its last user.
		-- Animated samples must first acquire a private writable image.
		reuse = previous ~= nil and view.sharedKey == nil and previous.Size == Vector2.new(p.pw, p.ph)
		local allocated, result = pcall(function()
			return if reuse
				then previous
				else game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(p.pw, p.ph) })
		end)
		if not allocated or not result then
			return false, "native-editable-shadow-allocation-failed"
		end
		image = result
		local written, writeFailure = pcall(view.upload, result, p, data)
		if not written then
			if not reuse then
				result:Destroy()
			end
			return false, tostring(writeFailure)
		end
	end
	local target = assert(image)
	local ok, err = pcall(function()
		view.label.ImageContent = Content.fromObject(target)
		view.label.ScaleType = if p.slice then Enum.ScaleType.Slice else Enum.ScaleType.Stretch
		view.label.SliceCenter = if p.slice then p.slice.center else Rect.new()
		view.label.SliceScale = if p.slice then 1 / scale else 1
		view.label.Position = position
		view.label.Size = size
	end)
	if not ok then
		if not entry and not reuse then
			target:Destroy()
		end
		return false, tostring(err)
	end
	if share then
		if not entry then
			entry = { image = target, references = 0 }
			sharedRasters[p.key] = entry
		end
		local shared = assert(entry)
		shared.references += 1
	end
	local oldKey = view.sharedKey
	view.image = target
	view.sharedKey = if share then p.key else nil
	view.key = p.key
	view.bounds = p
	if previous ~= target then
		release(previous, oldKey)
	end
	return true, nil
end
local function prepareTransition(from: Spec, to: Spec, width: number, height: number): (Prepared?, string?)
	local startBounds, failure = NativeShadow.prepare(from, width, height)
	local endBounds, endFailure = NativeShadow.prepare(to, width, height)
	if not startBounds or not endBounds then
		return nil, failure or endFailure
	end
	local x = math.min(startBounds.x, endBounds.x)
	local y = math.min(startBounds.y, endBounds.y)
	local w = math.max(startBounds.x + startBounds.width, endBounds.x + endBounds.width) - x
	local h = math.max(startBounds.y + startBounds.height, endBounds.y + endBounds.height) - y
	local bounds: Prepared = {
		x = x,
		y = y,
		width = w,
		height = h,
		pw = w * scale,
		ph = h * scale,
		key = "transition",
	}
	bounds.slice = ShadowSlice.prepare(width, bounds.x, bounds.width, bounds.ph, ShadowSlice.edge(from, to))
	if bounds.slice then
		bounds.pw = bounds.slice.pixelWidth
	end
	local work = 0
	for index = 1, math.max(#from.layers, #to.layers) do
		local a, b = from.layers[index], to.layers[index]
		work += 4 * math.ceil(math.max(if a then a.blur else 0, if b then b.blur else 0) * scale * 1.5) + 3
	end
	if bounds.pw > 1024 or bounds.ph > 1024 or bounds.pw * bounds.ph * work > 16000000 then
		return nil, "raster-transition-budget-provider-required"
	end
	return bounds, nil
end

local function prepareFrame(spec: Spec, bounds: Prepared, width: number, height: number): (Prepared?, string?)
	-- A fixed raster envelope preserves the native body's size and hit target.
	local prepared, failure = NativeShadow.prepare(spec, width, height)
	if not prepared then
		return nil, failure
	end
	local frame = table.clone(bounds)
	frame.key = prepared.key
		.. string.format(
			"|transition:%.17g:%.17g:%d:%d:%.17g",
			frame.x,
			frame.y,
			frame.pw,
			frame.ph,
			if frame.slice then frame.slice.bodyWidth else width
		)
	return frame, nil
end

function NativeShadow.create(parent: Instance, onDiagnostic: ((string) -> ())?, onProfile: Profiler.Sink?): View
	local label = Instance.new("ImageLabel")
	label.Name = "CssShadow"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Active = false
	label.Selectable = false
	label.Parent = parent
	local view: View
	local backend: ShadowTransition.Backend<Prepared> = {
		key = function(plan)
			return plan.key
		end,
		prepareTransition = prepareTransition,
		prepareFrame = prepareFrame,
		write = function(spec, prepared, width, height, share)
			return write(view, spec, prepared, width, height, share)
		end,
		releaseTransient = function(settled)
			view.workspace = nil
			if settled then
				view.cache = nil
			end
		end,
	}
	view = {
		parent = label,
		backend = backend,
		label = label,
		image = nil,
		sharedKey = nil,
		key = nil,
		current = nil,
		target = nil,
		targetKey = nil,
		width = nil,
		height = nil,
		running = nil,
		playback = nil,
		driver = nil,
		tween = nil,
		changed = nil,
		completed = nil,
		onDiagnostic = onDiagnostic,
		rasterize = Profiler.wrap(onProfile, "shadow.raster", pixels),
		upload = Profiler.wrap(onProfile, "shadow.upload", upload),
		destroyed = false,
		cache = nil,
		bounds = nil,
		workspace = nil,
	} :: View
	return view
end

function NativeShadow.apply(
	view: View,
	spec: Spec,
	prepared: Prepared,
	width: number,
	height: number,
	config: Transitions.Config?
): (boolean, string?)
	return ShadowTransition.apply(view, spec, prepared, width, height, config)
end
function NativeShadow.destroy(view: View)
	if view.destroyed then
		return
	end
	ShadowTransition.destroy(view)
	view.current = nil
	view.cache = nil
	view.bounds = nil
	view.target = nil
	view.onDiagnostic = nil
	view.rasterize = pixels
	view.upload = upload
	view.label:Destroy()
	release(view.image, view.sharedKey)
	view.image = nil
	view.sharedKey = nil
	view.key = nil
end
return NativeShadow
