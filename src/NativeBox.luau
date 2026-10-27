--!strict

local BoxModel = require(script.Parent.BoxModel)
local NativeDimensions = require(script.Parent.NativeDimensions)
local NativeEditor = require(script.Parent.NativeEditor)
local NativeImage = require(script.Parent.NativeImage)
local NativeClip = require(script.Parent.NativeClip)
local InsetCorners = require(script.Parent.InsetCorners)
local NativeShadow = require(script.Parent.NativeShadow)
local Profiler = require(script.Parent.Profiler)
local Transitions = require(script.Parent.Transitions)

export type Color = { value: Color3, transparency: number }
export type Corners = { topLeft: number, topRight: number, bottomRight: number, bottomLeft: number }
export type Paint = {
	background: Color?,
	backgroundBox: { x: number, y: number, width: number, height: number }?,
	border: { width: number, color: Color }?,
	borderEdges: { widths: { [string]: number }, color: Color }?,
	outline: { width: number, offset: number, color: Color }?,
	-- Topmost first. These are the supported zero-offset/blur outer shadows.
	shadows: { { width: number, color: Color } }?,
	-- Disjoint sharp inset bands, bottommost layer first, inside padding edge.
	insetShadows: { { x: number, y: number, width: number, height: number, color: Color } }?,
	-- Sharp outer bands with border-box knockout, bottommost layer first.
	outerShadows: { { x: number, y: number, width: number, height: number, color: Color } }?,
	rasterShadows: NativeShadow.Spec?,
	shadowTransition: Transitions.Config?,
	corners: Corners?,
	clip: boolean?,
	-- Explicit native clipping policy for transformed scopes, not a CSS value.
	groupClip: boolean?,
	clipBox: { x: number, y: number, width: number, height: number }?,
}
export type Capabilities =
	{ innerStroke: boolean, outerStroke: boolean, perCornerRadius: boolean, canvasGroup: boolean }
export type Kind = "box" | "button" | "text-input" | "image"

local NativeBox = {}
NativeBox.__index = NativeBox

local cachedCapabilities: Capabilities? = nil

local function capabilities(): Capabilities
	if cachedCapabilities then
		return table.clone(cachedCapabilities)
	end
	local stroke = Instance.new("UIStroke")
	local innerStroke = pcall(function()
		stroke.BorderStrokePosition = Enum.BorderStrokePosition.Inner
		stroke.BorderOffset = UDim.new(0, 0)
		stroke.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize
	end)
	local outerStroke = pcall(function()
		stroke.BorderStrokePosition = Enum.BorderStrokePosition.Outer
		stroke.BorderOffset = UDim.new(0, 0)
		stroke.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize
		stroke.ZIndex = 2
	end)
	stroke:Destroy()
	local corner = Instance.new("UICorner")
	local perCornerRadius = pcall(function()
		corner.TopLeftRadius = UDim.new()
		corner.TopRightRadius = UDim.new()
		corner.BottomLeftRadius = UDim.new()
		corner.BottomRightRadius = UDim.new()
	end)
	corner:Destroy()
	local result = {
		innerStroke = innerStroke,
		outerStroke = outerStroke,
		perCornerRadius = perCornerRadius,
		canvasGroup = NativeClip.available(),
	}
	cachedCapabilities = result
	return table.clone(result)
end

local function frame(name: string, kind: Kind?): GuiObject
	local result: GuiObject
	if kind == "button" then
		local button = Instance.new("TextButton")
		button.Text = ""
		button.RichText = false
		button.AutoLocalize = false
		button.TextScaled = false
		button.TextWrapped = false
		button.AutoButtonColor = false
		button.Modal = false
		button.Interactable = false
		result = button
	elseif kind == "text-input" then
		local box = Instance.new("TextBox")
		box.Text = ""
		box.TextEditable = false
		box.Interactable = false
		result = box
	else
		result = Instance.new("Frame")
	end
	result.Name = name
	result.AnchorPoint = Vector2.zero
	result.Position = UDim2.fromOffset(0, 0)
	result.Size = UDim2.fromOffset(0, 0)
	result.AutomaticSize = Enum.AutomaticSize.None
	result.BackgroundTransparency = 1
	result.BorderSizePixel = 0
	result.ClipsDescendants = false
	result.Active = false
	result.Selectable = false
	return result
end

function NativeBox.new(
	parent: Instance,
	kind: Kind?,
	onDiagnostic: ((string) -> ())?,
	onContextChanged: (() -> ())?,
	onProfile: Profiler.Sink?
): Box
	local nativeKind: Kind = kind or "box"
	assert(
		nativeKind == "box" or nativeKind == "button" or nativeKind == "text-input" or nativeKind == "image",
		"Unsupported native box kind"
	)
	local outer = frame("CssBox", if nativeKind == "text-input" then "box" else nativeKind)
	outer.Visible = false
	-- Reserve decoration order before content; toggling an inset fill must
	-- not replace native content or put paint above interactive descendants.
	local background = frame("Background") :: Frame
	background.Visible = false
	background.Parent = outer
	local shadowPaint = frame("ShadowRectangles") :: Frame
	shadowPaint.Size = UDim2.fromScale(1, 1)
	shadowPaint.Parent = outer
	local content = frame("Content") :: Frame
	content.Parent = outer
	-- The native editor owns text clipping/caret scrolling; the outer box owns
	-- CSS paint. Clipping the paint box would also cut off its shadows/rings.
	local target = outer
	if nativeKind == "text-input" then
		target = frame("Editor", "text-input")
		target.Size = UDim2.fromScale(1, 1)
		target.Parent = content
	end
	local self = setmetatable({
		frame = outer,
		target = target,
		kind = nativeKind,
		content = content,
		_background = background,
		_shadowPaint = shadowPaint,
		_shadowRects = {} :: { Frame },
		_raster = nil :: NativeShadow.View?,
		_backgroundCorner = nil :: UICorner?,
		_overlay = nil :: Frame?,
		_negativeOverlay = nil :: Frame?,
		_overlayZeroAxes = nil :: number?,
		_capabilities = capabilities(),
		_stroke = nil :: UIStroke?,
		_outline = nil :: UIStroke?,
		_shadowStrokes = {} :: { UIStroke },
		_borderEdges = {} :: { Frame },
		_editor = if target:IsA("TextBox")
			then NativeEditor.new(target, onDiagnostic, content, outer)
			else nil :: NativeEditor.View?,
		_image = if nativeKind == "image"
			then NativeImage.create(content, onDiagnostic, onContextChanged)
			else nil :: NativeImage.View?,
		_corner = nil :: UICorner?,
		_clip = nil :: NativeClip.View?,
		_rectClip = nil :: Frame?,
		_onDiagnostic = onDiagnostic,
		_onContextChanged = onContextChanged,
		_onProfile = onProfile,
		_destroying = nil :: RBXScriptConnection?,
		_destroyed = false,
	}, NativeBox)
	self._destroying = outer.Destroying:Connect(function()
		self._destroyed = true
		self._stroke = nil
		self._outline = nil
		table.clear(self._shadowStrokes)
		table.clear(self._shadowRects)
		if self._raster then
			NativeShadow.destroy(self._raster)
			self._raster = nil
		end
		table.clear(self._borderEdges)
		self._corner = nil
		self._backgroundCorner = nil
		self._rectClip = nil
		self._overlay = nil
		self._negativeOverlay = nil
		self._overlayZeroAxes = nil
		self._onDiagnostic = nil
		self._onContextChanged = nil
		self._onProfile = nil
		if self._clip then
			self._clip:destroy()
			self._clip = nil
		end
		if self._image then
			self._image:destroy()
			self._image = nil
		end
		if self._editor then
			self._editor:destroy()
			self._editor = nil
		end
		if self._destroying then
			self._destroying:Disconnect()
			self._destroying = nil
		end
	end)
	outer.Parent = parent
	return self
end

local function nonnegative(value: number): boolean
	return value >= 0 and value < math.huge
end

local function validColor(color: Color): boolean
	local value = color.value
	return value.R >= 0
		and value.R <= 1
		and value.G >= 0
		and value.G <= 1
		and value.B >= 0
		and value.B <= 1
		and color.transparency >= 0
		and color.transparency <= 1
end

-- A preparation is immutable and keeps the exact paint/geometry it validated.
-- Scene preflight passes it through to commit instead of preparing it twice.
export type Prepared = {
	geometry: BoxModel.Geometry,
	paint: Paint,
	raster: NativeShadow.Prepared?,
	clip: { position: UDim2, size: UDim2, corners: InsetCorners.Encoded? }?,
	background: { position: UDim2, size: UDim2, corners: InsetCorners.Encoded? }?,
	edges: { { position: UDim2, size: UDim2 } },
	rectShadows: { { position: UDim2, size: UDim2, color: Color } },
	size: UDim2,
	position: UDim2,
	contentSize: UDim2,
	radii: { [string]: UDim },
	outlineOffset: UDim?,
	roundedClip: boolean,
	individualCorners: boolean,
}

local function prepare(
	geometry: BoxModel.Geometry,
	paint: Paint,
	reference: Vector2?,
	caps: Capabilities
): (Prepared?, string?)
	for _, value in
		{
			geometry.width,
			geometry.height,
			geometry.contentX,
			geometry.contentY,
			geometry.contentWidth,
			geometry.contentHeight,
		}
	do
		if not nonnegative(value) then
			return nil, "invalid-box-geometry"
		end
	end
	if paint.background and not validColor(paint.background) then
		return nil, "display-gamut-mapping-required"
	end
	local size, sizeFailure = NativeDimensions.pair(geometry.width, geometry.height, reference)
	local contentReference = Vector2.new(geometry.width, geometry.height)
	local position, positionFailure = NativeDimensions.pair(geometry.contentX, geometry.contentY, contentReference)
	local contentSize, contentFailure =
		NativeDimensions.pair(geometry.contentWidth, geometry.contentHeight, contentReference)
	if not size or not position or not contentSize then
		return nil, sizeFailure or positionFailure or contentFailure
	end
	local border = paint.border
	if border then
		if not nonnegative(border.width) or not validColor(border.color) then
			return nil, "invalid-border-paint"
		end
		if border.width > 0 and not caps.innerStroke then
			return nil, "native-inner-stroke-unavailable"
		end
	end
	if paint.shadowTransition then
		local invalid = Transitions.validate(paint.shadowTransition)
		if invalid then
			return nil, invalid
		end
	end
	local radii = paint.corners
	local raster: NativeShadow.Prepared? = nil
	if paint.rasterShadows then
		if
			(paint.shadows and #paint.shadows > 0)
			or (paint.outerShadows and #paint.outerShadows > 0)
			or (paint.insetShadows and #paint.insetShadows > 0)
		then
			return nil, "mixed-raster-shadow-backends-required"
		end
		local failure: string?
		raster, failure = NativeShadow.prepare(paint.rasterShadows, geometry.width, geometry.height)
		if not raster then
			return nil, failure
		end
		if paint.clip and not paint.clipBox then
			return nil, "outer-shadow-own-clip-provider-required"
		end
	end
	local rectShadows: { { position: UDim2, size: UDim2, color: Color } } = {}
	for _, rect in paint.outerShadows or {} do
		if paint.clip and not paint.clipBox then
			return nil, "outer-shadow-own-clip-provider-required"
		elseif paint.shadows and #paint.shadows > 0 then
			return nil, "mixed-outer-shadow-backends-required"
		elseif
			radii and (radii.topLeft ~= 0 or radii.topRight ~= 0 or radii.bottomLeft ~= 0 or radii.bottomRight ~= 0)
		then
			return nil, "rounded-offset-shadow-backend-required"
		end
		for _, value in { rect.x, rect.y, rect.width, rect.height, rect.x + rect.width, rect.y + rect.height } do
			if value ~= value or math.abs(value) == math.huge then
				return nil, "invalid-outer-shadow-rectangle"
			end
		end
		if rect.width < 0 or rect.height < 0 or not validColor(rect.color) then
			return nil, "invalid-outer-shadow-rectangle"
		end
		if
			rect.width > 0
			and rect.height > 0
			and rect.x < geometry.width
			and rect.x + rect.width > 0
			and rect.y < geometry.height
			and rect.y + rect.height > 0
		then
			return nil, "outer-shadow-border-box-knockout-required"
		end
		local point, pointFailure = NativeDimensions.pair(rect.x, rect.y, contentReference)
		local extent, extentFailure = NativeDimensions.pair(rect.width, rect.height, contentReference)
		if not point or not extent then
			return nil, pointFailure or extentFailure
		end
		table.insert(rectShadows, { position = point, size = extent, color = rect.color })
	end
	for _, rect in paint.insetShadows or {} do
		if
			not nonnegative(rect.x)
			or not nonnegative(rect.y)
			or not nonnegative(rect.width)
			or not nonnegative(rect.height)
			or rect.x + rect.width > geometry.width
			or rect.y + rect.height > geometry.height
			or not validColor(rect.color)
		then
			return nil, "invalid-inset-shadow-rectangle"
		elseif
			radii and (radii.topLeft ~= 0 or radii.topRight ~= 0 or radii.bottomLeft ~= 0 or radii.bottomRight ~= 0)
		then
			return nil, "rounded-inset-shadow-backend-required"
		end
		local point, pointFailure = NativeDimensions.pair(rect.x, rect.y, contentReference)
		local extent, extentFailure = NativeDimensions.pair(rect.width, rect.height, contentReference)
		if not point or not extent then
			return nil, pointFailure or extentFailure
		end
		table.insert(rectShadows, { position = point, size = extent, color = rect.color })
	end
	local edges: { { position: UDim2, size: UDim2 } } = {}
	if paint.borderEdges then
		local edgePaint = paint.borderEdges
		if border or not validColor(edgePaint.color) then
			return nil, "invalid-border-edge-paint"
		end
		for _, side in { "top", "right", "bottom", "left" } do
			local width = edgePaint.widths[side]
			if width == nil or not nonnegative(width) then
				return nil, "invalid-border-edge-width"
			end
		end
		if radii and (radii.topLeft ~= 0 or radii.topRight ~= 0 or radii.bottomLeft ~= 0 or radii.bottomRight ~= 0) then
			return nil, "nonuniform-rounded-border-provider-required"
		end
		local w, h = geometry.width, geometry.height
		local t, r, b, l = edgePaint.widths.top, edgePaint.widths.right, edgePaint.widths.bottom, edgePaint.widths.left
		if l + r > w or t + b > h then
			return nil, "border-edges-exceed-border-box"
		end
		-- Same-color corners permit disjoint rectangles: horizontal bands own
		-- the corners, so translucent borders never double-paint their joins.
		for _, rect in { { 0, 0, w, t }, { 0, h - b, w, b }, { 0, t, l, h - t - b }, { w - r, t, r, h - t - b } } do
			if rect[3] == 0 or rect[4] == 0 then
				continue
			end
			local point, pointFailure = NativeDimensions.pair(rect[1], rect[2], contentReference)
			local extent, extentFailure = NativeDimensions.pair(rect[3], rect[4], contentReference)
			if not point or not extent then
				return nil, pointFailure or extentFailure
			end
			table.insert(edges, { position = point, size = extent })
		end
	end
	for _, shadow in paint.shadows or {} do
		if not nonnegative(shadow.width) or not validColor(shadow.color) then
			return nil, "invalid-shadow-ring-paint"
		elseif not caps.outerStroke then
			return nil, "native-outer-stroke-unavailable"
		end
		if radii and shadow.width > 0 then
			for _, radius in { radii.topLeft, radii.topRight, radii.bottomLeft, radii.bottomRight } do
				-- CSS adjusts small-radius spread curvature nonlinearly. A native
				-- outer stroke alone cannot reproduce it. Mixed zero radii also
				-- need a native join check before accepting UICorner's round joins.
				if radius < shadow.width then
					return nil, "shadow-spread-corner-geometry-required"
				end
			end
		end
	end
	local outlineOffset: UDim? = nil
	if paint.outline then
		local outline = paint.outline
		if not nonnegative(outline.width) or not validColor(outline.color) then
			return nil, "invalid-outline-paint"
		end
		if not caps.outerStroke then
			return nil, "native-outer-stroke-unavailable"
		end
		if outline.offset < -math.min(geometry.width, geometry.height) / 2 then
			return nil, "outline-negative-offset-axis-clamping-required"
		end
		local encoded, failure = NativeDimensions.axis(outline.offset, math.min(geometry.width, geometry.height))
		if not encoded then
			return nil, failure
		end
		outlineOffset = encoded
	end
	local encodedRadii: { [string]: UDim } = {}
	local background: { position: UDim2, size: UDim2, corners: InsetCorners.Encoded? }? = nil
	if paint.background and paint.backgroundBox then
		local area = paint.backgroundBox
		if
			not nonnegative(area.x)
			or not nonnegative(area.y)
			or not nonnegative(area.width)
			or not nonnegative(area.height)
			or area.x + area.width > geometry.width
			or area.y + area.height > geometry.height
		then
			return nil, "invalid-background-paint-box"
		end
		local point, pointFailure = NativeDimensions.pair(area.x, area.y, contentReference)
		local extent, extentFailure = NativeDimensions.pair(area.width, area.height, contentReference)
		if not point or not extent then
			return nil, pointFailure or extentFailure
		end
		local corners, cornerFailure = InsetCorners.resolve({
			width = geometry.width,
			height = geometry.height,
			x = area.x,
			y = area.y,
			innerWidth = area.width,
			innerHeight = area.height,
			corners = if area.width > 0 and area.height > 0 then paint.corners else nil,
			perCornerRadius = caps.perCornerRadius,
		})
		if cornerFailure then
			return nil, cornerFailure
		end
		background = { position = point, size = extent, corners = corners }
	end
	local uniform = true
	local roundedClip = false
	if radii then
		for _, value in { radii.topLeft, radii.topRight, radii.bottomLeft, radii.bottomRight } do
			if not nonnegative(value) then
				return nil, "invalid-corner-radius"
			end
		end
		uniform = radii.topLeft == radii.topRight
			and radii.topLeft == radii.bottomLeft
			and radii.topLeft == radii.bottomRight
		local cornerValues: { [string]: number } = {
			topLeft = radii.topLeft,
			topRight = radii.topRight,
			bottomLeft = radii.bottomLeft,
			bottomRight = radii.bottomRight,
		}
		for name, radius in cornerValues do
			local encoded, failure = NativeDimensions.axis(radius, math.min(geometry.width, geometry.height))
			if not encoded then
				return nil, failure
			end
			encodedRadii[name] = encoded
		end
		if not uniform and not caps.perCornerRadius then
			return nil, "native-per-corner-radius-unavailable"
		end
		local maximum = math.min(geometry.width, geometry.height) / 2
		if
			radii.topLeft > maximum
			or radii.topRight > maximum
			or radii.bottomLeft > maximum
			or radii.bottomRight > maximum
		then
			return nil, "native-radius-clamping-differs"
		end
		if
			paint.clip and (radii.topLeft > 0 or radii.topRight > 0 or radii.bottomLeft > 0 or radii.bottomRight > 0)
		then
			roundedClip = true
		end
	end
	local clip: { position: UDim2, size: UDim2, corners: InsetCorners.Encoded? }? = nil
	if paint.clip and paint.clipBox then
		local area = paint.clipBox
		if
			not nonnegative(area.x)
			or not nonnegative(area.y)
			or not nonnegative(area.width)
			or not nonnegative(area.height)
			or area.x + area.width > geometry.width
			or area.y + area.height > geometry.height
		then
			return nil, "invalid-overflow-clip-box"
		end
		local point, pointFailure = NativeDimensions.pair(area.x, area.y, contentReference)
		local extent, extentFailure = NativeDimensions.pair(area.width, area.height, contentReference)
		if not point or not extent then
			return nil, pointFailure or extentFailure
		end
		local corners, cornerFailure = InsetCorners.resolve({
			width = geometry.width,
			height = geometry.height,
			x = area.x,
			y = area.y,
			innerWidth = area.width,
			innerHeight = area.height,
			corners = if area.width > 0 and area.height > 0 then paint.corners else nil,
			perCornerRadius = caps.perCornerRadius,
		})
		if cornerFailure then
			return nil, cornerFailure
		end
		local clipReference = Vector2.new(area.width, area.height)
		local shifted, shiftFailure =
			NativeDimensions.pair(geometry.contentX - area.x, geometry.contentY - area.y, clipReference)
		local shiftedSize, shiftedSizeFailure =
			NativeDimensions.pair(geometry.contentWidth, geometry.contentHeight, clipReference)
		if not shifted or not shiftedSize then
			return nil, shiftFailure or shiftedSizeFailure
		end
		position, contentSize = shifted, shiftedSize
		clip = { position = point, size = extent, corners = corners }
		roundedClip = corners ~= nil
	end
	roundedClip = roundedClip or (paint.clip == true and paint.groupClip == true)
	if roundedClip and not next(encodedRadii) then
		local zero = UDim.new()
		encodedRadii = { topLeft = zero, topRight = zero, bottomLeft = zero, bottomRight = zero }
	end
	if roundedClip and not caps.canvasGroup then
		return nil, "native-canvas-group-unavailable"
	end
	return {
		geometry = geometry,
		paint = paint,
		raster = raster,
		clip = clip,
		background = background,
		edges = edges,
		rectShadows = rectShadows,
		size = size,
		position = position,
		contentSize = contentSize,
		radii = encodedRadii,
		outlineOffset = outlineOffset,
		roundedClip = roundedClip,
		individualCorners = not uniform,
	},
		nil
end

function NativeBox.validate(
	geometry: BoxModel.Geometry,
	paint: Paint,
	reference: Vector2?
): (boolean, string?, boolean?)
	local prepared, failure = prepare(geometry, paint, reference, capabilities())
	return prepared ~= nil, failure, if prepared then prepared.roundedClip else nil
end

function NativeBox.prepare(geometry: BoxModel.Geometry, paint: Paint, reference: Vector2?): (Prepared?, string?)
	return prepare(geometry, paint, reference, capabilities())
end

function NativeBox.apply(
	self: Box,
	geometry: BoxModel.Geometry,
	paint: Paint,
	reference: Vector2?,
	visible: boolean?
): (boolean, string?)
	if self._destroyed then
		return false, "box-destroyed"
	end
	local prepared, failure = prepare(geometry, paint, reference, self._capabilities)
	if not prepared then
		return false, failure
	end
	return self:applyPrepared(prepared, visible)
end

local function overlaySize(size: UDim2, zeroAxes: number?): UDim2
	if not zeroAxes then
		return size
	end
	-- Bits 1/2 mark zero content width/height. Keep only scalar ownership
	-- state; empty boxes with no overlay allocate no extra dimension object.
	local zeroX, zeroY = zeroAxes % 2 == 1, zeroAxes >= 2
	return UDim2.new(
		if zeroX then 0 else size.X.Scale,
		if zeroX then 1 else size.X.Offset,
		if zeroY then 0 else size.Y.Scale,
		if zeroY then 1 else size.Y.Offset
	)
end

function NativeBox.applyPrepared(self: Box, prepared: Prepared, visible: boolean?): (boolean, string?)
	if self._destroyed then
		return false, "box-destroyed"
	end
	local geometry, paint = prepared.geometry, prepared.paint
	if self.kind == "text-input" and paint.clip and (paint.clipBox or paint.corners) then
		return false, "native-editor-inner-clip-provider-required"
	end
	if self.kind == "text-input" and paint.insetShadows and #paint.insetShadows > 0 then
		return false, "native-editor-inset-shadow-provider-required"
	end
	if prepared.roundedClip then
		local eligible, reason = NativeClip.checkContext(self.frame)
		if not eligible then
			return false, reason
		end
	end
	local border, radii = paint.border, paint.corners
	local encodedRadii = prepared.radii
	-- Only this view owns these instances. Layout supplies used geometry; effects
	-- and decorative helpers never become logical CSS children or layout items.
	self.frame.Size = prepared.size
	if self._destroyed then
		return false, "box-destroyed"
	end
	local clipParent: GuiObject = self.frame
	if prepared.roundedClip then
		local clip = self._clip or NativeClip.create(self.frame, self._onDiagnostic, self._onContextChanged)
		if self._destroyed then
			clip:destroy()
			return false, "box-destroyed"
		end
		self._clip = clip
		local inner = prepared.clip
		local innerCorners = if inner then inner.corners else nil
		clip.group.Position = if inner then inner.position else UDim2.fromOffset(0, 0)
		clip.group.Size = if inner then inner.size else UDim2.fromScale(1, 1)
		local clipped, clipFailure = clip:apply(
			if innerCorners then innerCorners.radii else encodedRadii,
			if innerCorners then innerCorners.individual else prepared.individualCorners
		)
		if not clipped then
			return false, clipFailure
		end
		clipParent = clip.group
	elseif prepared.clip then
		local clip = self._rectClip or frame("PaddingClip") :: Frame
		clip.Position = prepared.clip.position
		clip.Size = prepared.clip.size
		clip.ClipsDescendants = true
		clip.ZIndex = self.frame.ZIndex
		clip.Parent = self.frame
		if self._destroyed then
			clip:Destroy()
			return false, "box-destroyed"
		end
		self._rectClip = clip
		clipParent = clip
	end
	self.content.Parent = clipParent
	if self._destroyed then
		return false, "box-destroyed"
	end
	if self._overlay then
		self._overlay.Parent = clipParent
	end
	if self._negativeOverlay then
		self._negativeOverlay.Parent = clipParent
	end
	if self._clip and not prepared.roundedClip then
		local clip = self._clip
		if self._destroyed then
			return false, "box-destroyed"
		end
		clip:destroy()
		self._clip = nil
	end
	if self._rectClip and (not prepared.clip or prepared.roundedClip) then
		self._rectClip:Destroy()
		self._rectClip = nil
	end
	if self._destroyed then
		return false, "box-destroyed"
	end
	self.content.Position = prepared.position
	self.content.Size = prepared.contentSize
	local zeroX, zeroY = geometry.contentWidth == 0, geometry.contentHeight == 0
	self._overlayZeroAxes = if zeroX or zeroY then (if zeroX then 1 else 0) + (if zeroY then 2 else 0) else nil
	if self._overlay then
		self._overlay.Position = prepared.position
		self._overlay.Size = overlaySize(prepared.contentSize, self._overlayZeroAxes)
	end
	if self._negativeOverlay then
		self._negativeOverlay.Position = prepared.position
		self._negativeOverlay.Size = overlaySize(prepared.contentSize, self._overlayZeroAxes)
	end
	self.frame.ClipsDescendants = paint.clip == true and not prepared.roundedClip and not prepared.clip
	if paint.background and not prepared.background then
		self.frame.BackgroundColor3 = paint.background.value
		self.frame.BackgroundTransparency = paint.background.transparency
	else
		self.frame.BackgroundTransparency = 1
	end
	local background = prepared.background
	self._background.Visible = background ~= nil
	if background then
		local color = paint.background
		assert(color, "Prepared background requires color paint")
		self._background.Position = background.position
		self._background.Size = background.size
		self._background.BackgroundColor3 = color.value
		self._background.BackgroundTransparency = color.transparency
		if background.corners then
			local corner = self._backgroundCorner or Instance.new("UICorner")
			corner.Name = "BackgroundCorners"
			corner.CornerRadius = background.corners.radii.topLeft
			if self._capabilities.perCornerRadius then
				corner.TopLeftRadius = background.corners.radii.topLeft
				corner.TopRightRadius = background.corners.radii.topRight
				corner.BottomLeftRadius = background.corners.radii.bottomLeft
				corner.BottomRightRadius = background.corners.radii.bottomRight
			end
			corner.Parent = self._background
			self._backgroundCorner = corner
		elseif self._backgroundCorner then
			self._backgroundCorner:Destroy()
			self._backgroundCorner = nil
		end
	elseif self._backgroundCorner then
		self._backgroundCorner:Destroy()
		self._backgroundCorner = nil
	end
	if prepared.raster and paint.rasterShadows then
		local view = self._raster or NativeShadow.create(self._shadowPaint, self._onDiagnostic, self._onProfile)
		self._raster = view
		view.label.ZIndex = self.frame.ZIndex
		local ok, rasterFailure = NativeShadow.apply(
			view,
			paint.rasterShadows,
			prepared.raster,
			geometry.width,
			geometry.height,
			paint.shadowTransition
		)
		if not ok then
			return false, rasterFailure
		end
	elseif self._raster then
		NativeShadow.destroy(self._raster)
		self._raster = nil
	end
	for index, rect in prepared.rectShadows do
		local view = self._shadowRects[index] or frame(`ShadowRect{index}`) :: Frame
		view.Position = rect.position
		view.Size = rect.size
		view.BackgroundColor3 = rect.color.value
		view.BackgroundTransparency = rect.color.transparency
		view.ZIndex = self.frame.ZIndex
		view.Parent = self._shadowPaint
		self._shadowRects[index] = view
	end
	for index = #self._shadowRects, #prepared.rectShadows + 1, -1 do
		self._shadowRects[index]:Destroy()
		table.remove(self._shadowRects, index)
	end
	local shadows = paint.shadows or {}
	for index, shadow in shadows do
		local stroke = self._shadowStrokes[index] or Instance.new("UIStroke")
		stroke.Name = `Shadow{index}`
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.BorderStrokePosition = Enum.BorderStrokePosition.Outer
		stroke.BorderOffset = UDim.new(0, 0)
		stroke.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize
		stroke.Enabled = true
		stroke.LineJoinMode = if radii then Enum.LineJoinMode.Round else Enum.LineJoinMode.Miter
		stroke.Thickness = shadow.width
		stroke.Color = shadow.color.value
		stroke.Transparency = shadow.color.transparency
		stroke.ZIndex = #shadows - index + 1
		stroke.Parent = self.frame
		self._shadowStrokes[index] = stroke
	end
	for index = #self._shadowStrokes, #shadows + 1, -1 do
		self._shadowStrokes[index]:Destroy()
		table.remove(self._shadowStrokes, index)
	end
	if border and border.width > 0 then
		local stroke = self._stroke or Instance.new("UIStroke")
		stroke.Name = "Border"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.BorderStrokePosition = Enum.BorderStrokePosition.Inner
		stroke.BorderOffset = UDim.new(0, 0)
		stroke.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize
		stroke.Enabled = true
		-- Miter joins omit the curved sections of an inner UIStroke with UICorner.
		-- Keep the native stroke continuous around rounded CSS boxes.
		stroke.LineJoinMode = if radii then Enum.LineJoinMode.Round else Enum.LineJoinMode.Miter
		stroke.Thickness = border.width
		stroke.Color = border.color.value
		stroke.Transparency = border.color.transparency
		if self._capabilities.outerStroke then
			stroke.ZIndex = #shadows + 1
		end
		stroke.Parent = self.frame
		self._stroke = stroke
	elseif self._stroke then
		self._stroke:Destroy()
		self._stroke = nil
	end
	local outline = paint.outline
	for index, edge in prepared.edges do
		local edgePaint = paint.borderEdges
		assert(edgePaint, "Prepared border rectangles require border paint")
		local view = self._borderEdges[index] or frame(`BorderEdge{index}`) :: Frame
		view.Position = edge.position
		view.Size = edge.size
		view.BackgroundColor3 = edgePaint.color.value
		view.BackgroundTransparency = edgePaint.color.transparency
		view.ZIndex = self.frame.ZIndex
		view.Parent = self.frame
		self._borderEdges[index] = view
	end
	for index = #self._borderEdges, #prepared.edges + 1, -1 do
		self._borderEdges[index]:Destroy()
		table.remove(self._borderEdges, index)
	end
	if outline and outline.width > 0 then
		local stroke = self._outline or Instance.new("UIStroke")
		stroke.Name = "Outline"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.BorderStrokePosition = Enum.BorderStrokePosition.Outer
		stroke.BorderOffset = prepared.outlineOffset :: UDim
		stroke.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize
		stroke.Enabled = true
		stroke.LineJoinMode = if radii then Enum.LineJoinMode.Round else Enum.LineJoinMode.Miter
		stroke.Thickness = outline.width
		stroke.Color = outline.color.value
		stroke.Transparency = outline.color.transparency
		stroke.ZIndex = #shadows + 2
		stroke.Parent = self.frame
		self._outline = stroke
	elseif self._outline then
		self._outline:Destroy()
		self._outline = nil
	end
	if radii then
		local corner = self._corner or Instance.new("UICorner")
		corner.Name = "Corners"
		corner.CornerRadius = encodedRadii.topLeft
		if self._capabilities.perCornerRadius then
			corner.TopLeftRadius = encodedRadii.topLeft
			corner.TopRightRadius = encodedRadii.topRight
			corner.BottomLeftRadius = encodedRadii.bottomLeft
			corner.BottomRightRadius = encodedRadii.bottomRight
		end
		corner.Parent = self.frame
		self._corner = corner
	elseif self._corner then
		self._corner:Destroy()
		self._corner = nil
	end
	self.frame.Visible = visible ~= false
	return true, nil
end

function NativeBox.applyEditor(self: Box, editor: NativeEditor.Prepared): (boolean, string?)
	if self._destroyed or not self._editor then
		return false, "native-editor-target-required"
	end
	return self._editor:apply(editor)
end

function NativeBox.setZIndex(self: Box, rank: number)
	if self._destroyed then
		return
	end
	self.frame.ZIndex = rank
	if self._destroyed then
		return
	end
	self.content.ZIndex = 1
	if self.target ~= self.frame then
		self.target.ZIndex = rank
	end
	self._background.ZIndex = rank
	self._shadowPaint.ZIndex = rank
	if self._raster then
		self._raster.label.ZIndex = rank
	end
	for _, rect in self._shadowRects do
		rect.ZIndex = rank
	end
	if self._rectClip then
		self._rectClip.ZIndex = rank
	end
	for _, edge in self._borderEdges do
		edge.ZIndex = rank
	end
	if not self._destroyed and self._overlay then
		self._overlay.ZIndex = 2
	end
	if self._negativeOverlay then
		self._negativeOverlay.ZIndex = 0
	end
	if not self._destroyed and self._clip then
		self._clip.group.ZIndex = rank
	end
end

function NativeBox.getOverlay(self: Box, negative: boolean?): Frame
	assert(not self._destroyed, "CSS box has been destroyed")
	local existing = if negative then self._negativeOverlay else self._overlay
	if existing then
		return existing
	end
	local overlay = frame(if negative then "NegativeOutOfFlow" else "OutOfFlow") :: Frame
	if negative then self._negativeOverlay = overlay else self._overlay = overlay end
	-- This sibling has the content origin without its UIListLayout. A zero
	-- content axis gets a native reference surface for fractional coordinates;
	-- the owner's actual content extent and logical node remain unchanged.
	overlay.Position = self.content.Position
	overlay.Size = overlaySize(self.content.Size, self._overlayZeroAxes)
	overlay.ZIndex = if negative then 0 else 2
	overlay.Parent = if self._clip then self._clip.group elseif self._rectClip then self._rectClip else self.frame
	return overlay
end

function NativeBox.applyImage(self: Box, image: NativeImage.Prepared): (boolean, string?)
	if self._destroyed or not self._image then
		return false, "native-image-target-required"
	end
	self._image.frame.ZIndex = self.content.ZIndex
	self._image.label.ZIndex = self.content.ZIndex
	return self._image:apply(image)
end

function NativeBox.getRasterBounds(self: Box): { x: number, y: number, width: number, height: number }?
	local view = self._raster
	local p = if view then view.bounds else nil
	return if p then { x = p.x, y = p.y, width = p.width, height = p.height } else nil
end

function NativeBox.getImageLabel(self: Box): ImageLabel?
	local view = self._image
	return if not self._destroyed and view and not view._destroyed then view.label else nil
end

function NativeBox.destroy(self: Box)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._onDiagnostic = nil
	self._onContextChanged = nil
	self._onProfile = nil
	if self._clip then
		self._clip:destroy()
		self._clip = nil
	end
	if self._image then
		self._image:destroy()
		self._image = nil
	end
	if self._editor then
		self._editor:destroy()
		self._editor = nil
	end
	if self._destroying then
		self._destroying:Disconnect()
		self._destroying = nil
	end
	if self._raster then
		NativeShadow.destroy(self._raster)
		self._raster = nil
	end
	self.frame:Destroy()
	self._overlay = nil
	self._negativeOverlay = nil
	self._overlayZeroAxes = nil
	self._stroke = nil
	self._outline = nil
	table.clear(self._shadowStrokes)
	table.clear(self._shadowRects)
	if self._raster then
		NativeShadow.destroy(self._raster)
		self._raster = nil
	end
	table.clear(self._borderEdges)
	self._corner = nil
	self._backgroundCorner = nil
	self._rectClip = nil
end

export type Box = typeof(setmetatable(
	{} :: {
		frame: GuiObject,
		target: GuiObject,
		kind: Kind,
		content: Frame,
		_background: Frame,
		_shadowPaint: Frame,
		_shadowRects: { Frame },
		_raster: NativeShadow.View?,
		_backgroundCorner: UICorner?,
		_overlay: Frame?,
		_negativeOverlay: Frame?,
		_overlayZeroAxes: number?,
		_capabilities: Capabilities,
		_stroke: UIStroke?,
		_outline: UIStroke?,
		_shadowStrokes: { UIStroke },
		_borderEdges: { Frame },
		_editor: NativeEditor.View?,
		_image: NativeImage.View?,
		_corner: UICorner?,
		_clip: NativeClip.View?,
		_rectClip: Frame?,
		_onDiagnostic: ((string) -> ())?,
		_onContextChanged: (() -> ())?,
		_onProfile: Profiler.Sink?,
		_destroying: RBXScriptConnection?,
		_destroyed: boolean,
	},
	NativeBox
))

return {
	create = NativeBox.new,
	capabilities = capabilities,
	validate = NativeBox.validate,
	prepare = NativeBox.prepare,
}
