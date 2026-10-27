--!strict

local Types = require(script.Parent.Types)
local ObjectFit = require(script.Parent.ObjectFit)
local NativeDimensions = require(script.Parent.NativeDimensions)
local ImageCorners = require(script.Parent.ImageCorners)
local NativeColors = require(script.Parent.NativeColors)
local NativeClip = require(script.Parent.NativeClip)

export type Source = string | Content
export type Data = { source: Source, natural: ObjectFit.Natural?, useCurrentColor: boolean? }
export type ClipContext = ImageCorners.Context
export type Prepared = {
	source: Source,
	position: UDim2,
	size: UDim2,
	scaleType: Enum.ScaleType,
	corners: ImageCorners.Encoded?,
	color: NativeColors.Color?,
	groupClip: boolean?,
}

local NativeImage = {}
NativeImage.__index = NativeImage
local contentAvailable: boolean? = nil

local function supportsContent(): boolean
	if contentAvailable == nil then
		local probe = Instance.new("ImageLabel")
		contentAvailable = pcall(function()
			probe.ImageContent = probe.ImageContent
		end)
		probe:Destroy()
	end
	return contentAvailable == true
end

local function initial(tokens: { Types.ValueToken }?, expected: string): boolean
	local found = false
	for _, token in tokens or {} do
		if token.kind ~= "space" and token.kind ~= "comment" then
			if found or token.kind ~= "word" or string.lower(token.value) ~= expected then
				return false
			end
			found = true
		end
	end
	return tokens == nil or found
end

-- Geometry preparation does not fetch resources or infer their natural size.
function NativeImage.prepare(
	style: Types.ComputedStyle,
	source: Source,
	context: ObjectFit.Context,
	clip: ClipContext?,
	tint: Types.RgbaColor?
): (Prepared?, string?)
	if typeof(source) ~= "string" and typeof(source) ~= "Content" then
		return nil, "native-image-resource-required"
	end
	if typeof(source) == "Content" and not supportsContent() then
		return nil, "native-image-content-unavailable"
	end
	if style.unresolved["image-rendering"] then
		return nil, `image-rendering:{style.unresolved["image-rendering"]}`
	end
	if not initial(style.properties["image-rendering"], "auto") then
		return nil, "image-resampling-provider-required"
	end
	if style.unresolved["image-orientation"] then
		return nil, `image-orientation:{style.unresolved["image-orientation"]}`
	end
	if not initial(style.properties["image-orientation"], "from-image") then
		return nil, "image-orientation-provider-required"
	end
	local rect, failure = ObjectFit.resolve(style, context)
	if not rect then
		return nil, failure
	end
	local corners: ImageCorners.Encoded? = nil
	if clip then
		if clip.geometry.contentWidth ~= context.width or clip.geometry.contentHeight ~= context.height then
			return nil, "image-clip-content-size-mismatch"
		end
		local reason: string? = nil
		corners, reason = ImageCorners.resolve(clip)
		if reason then
			return nil, reason
		end
	end
	local scaleType = Enum.ScaleType.Stretch
	if corners then
		local full = rect.x == 0 and rect.y == 0 and rect.width == context.width and rect.height == context.height
		if not full then
			local natural = context.natural
			local dimensionRatio = natural and natural.width and natural.height and natural.width / natural.height
			local nativeRatio = dimensionRatio or (natural and natural.ratio)
			local centered = rect.x == (context.width - rect.width) / 2 and rect.y == (context.height - rect.height) / 2
			if
				not nativeRatio
				or (dimensionRatio and natural and natural.ratio and natural.ratio ~= dimensionRatio)
				or not centered
			then
				return nil, "positioned-image-rounded-clip-provider-required"
			end
			local constrained = rect.width == context.width or rect.height == context.height
			if constrained and rect.width >= context.width and rect.height >= context.height then
				scaleType = Enum.ScaleType.Crop
			elseif constrained and rect.width <= context.width and rect.height <= context.height then
				scaleType = Enum.ScaleType.Fit
			else
				return nil, "positioned-image-rounded-clip-provider-required"
			end
		end
		-- UICorner affects the ImageLabel's own pixels. Keeping its native
		-- bounds at the content box clips Fit/Crop there without a mask tree.
		rect = { x = 0, y = 0, width = context.width, height = context.height }
	end
	local reference = Vector2.new(context.width, context.height)
	local position, positionFailure = NativeDimensions.pair(rect.x, rect.y, reference)
	local size, sizeFailure = NativeDimensions.pair(rect.width, rect.height, reference)
	if not position or not size then
		return nil, positionFailure or sizeFailure
	end
	local color: NativeColors.Color? = nil
	if tint then
		local colorFailure: string?
		color, colorFailure = NativeColors.fromRgba(tint)
		if not color then
			return nil, colorFailure
		end
	end
	return { source = source, position = position, size = size, scaleType = scaleType, corners = corners, color = color },
		nil
end

function NativeImage.new(parent: Instance, onDiagnostic: ((string) -> ())?, onContextChanged: (() -> ())?): View
	local frame = Instance.new("Frame")
	frame.Name = "CssImageViewport"
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.ClipsDescendants = true
	frame.Active = false
	frame.Selectable = false
	local label = Instance.new("ImageLabel")
	label.Name = "CssImage"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Image = ""
	label.ImageColor3 = Color3.new(1, 1, 1)
	label.ImageTransparency = 0
	label.ScaleType = Enum.ScaleType.Stretch
	label.ResampleMode = Enum.ResamplerMode.Default
	label.ImageRectOffset = Vector2.zero
	label.ImageRectSize = Vector2.zero
	label.Active = false
	label.Selectable = false
	label.Visible = false
	label.Parent = frame
	local self: View = setmetatable({
		frame = frame,
		label = label,
		_destroyed = false,
		_source = nil :: Source?,
		_corner = nil :: UICorner?,
		_clip = nil :: NativeClip.View?,
		_onDiagnostic = onDiagnostic,
		_onContextChanged = onContextChanged,
		_connections = {} :: { RBXScriptConnection },
	}, NativeImage)
	table.insert(
		self._connections,
		frame.Destroying:Connect(function()
			self:_release()
		end)
	)
	table.insert(
		self._connections,
		label.Destroying:Connect(function()
			self:destroy()
		end)
	)
	frame.Parent = parent
	return self
end

function NativeImage.apply(self: View, prepared: Prepared): (boolean, string?)
	if self._destroyed then
		return false, "image-view-destroyed"
	end
	if prepared.groupClip then
		local eligible, reason = NativeClip.checkContext(self.frame)
		if not eligible then
			return false, reason
		end
		local clip = self._clip or NativeClip.create(self.frame, self._onDiagnostic, self._onContextChanged)
		self._clip = clip
		clip.group.Name = "CssImageClip"
		clip.group.ZIndex = self.label.ZIndex
		local zero = UDim.new()
		local clipped, failure =
			clip:apply({ topLeft = zero, topRight = zero, bottomLeft = zero, bottomRight = zero }, false)
		if not clipped then
			return false, failure
		end
		self.label.Parent = clip.group
	elseif self._clip then
		self.label.Parent = self.frame
		self._clip:destroy()
		self._clip = nil
	end
	if self._destroyed then
		return false, "image-view-destroyed"
	end
	if self._source ~= prepared.source then
		local ok, failure = pcall(function()
			if typeof(prepared.source) == "string" then
				self.label.Image = prepared.source :: string
			else
				self.label.ImageContent = prepared.source :: Content
			end
		end)
		if not ok then
			return false, `native-image-resource-unavailable:{tostring(failure)}`
		end
		if self._destroyed then
			return false, "image-view-destroyed"
		end
		self._source = prepared.source
	end
	self.label.Position = prepared.position
	if self._destroyed then
		return false, "image-view-destroyed"
	end
	self.label.Size = prepared.size
	if self._destroyed then
		return false, "image-view-destroyed"
	end
	self.label.ScaleType = prepared.scaleType
	self.label.ImageColor3 = if prepared.color then prepared.color.value else Color3.new(1, 1, 1)
	self.label.ImageTransparency = if prepared.color then prepared.color.transparency else 0
	if self._destroyed then
		return false, "image-view-destroyed"
	end
	if prepared.corners then
		local corner = self._corner or Instance.new("UICorner")
		corner.Name = "ContentCorners"
		corner.CornerRadius = prepared.corners.radii.topLeft
		if prepared.corners.individual then
			corner.TopLeftRadius = prepared.corners.radii.topLeft
			corner.TopRightRadius = prepared.corners.radii.topRight
			corner.BottomLeftRadius = prepared.corners.radii.bottomLeft
			corner.BottomRightRadius = prepared.corners.radii.bottomRight
		end
		corner.Parent = self.label
		if self._destroyed then
			corner:Destroy()
			return false, "image-view-destroyed"
		end
		self._corner = corner
	elseif self._corner then
		self._corner:Destroy()
		self._corner = nil
	end
	if self._destroyed then
		return false, "image-view-destroyed"
	end
	self.label.Visible = true
	return true, nil
end

function NativeImage._release(self: View)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._source = nil
	self._corner = nil
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	if self._clip then
		self._clip:destroy()
		self._clip = nil
	end
	self._onDiagnostic, self._onContextChanged = nil, nil
end

function NativeImage.destroy(self: View)
	if self._destroyed then
		return
	end
	self:_release()
	self.frame:Destroy()
end

export type View = typeof(setmetatable(
	{} :: {
		frame: Frame,
		label: ImageLabel,
		_destroyed: boolean,
		_source: Source?,
		_corner: UICorner?,
		_clip: NativeClip.View?,
		_onDiagnostic: ((string) -> ())?,
		_onContextChanged: (() -> ())?,
		_connections: { RBXScriptConnection },
	},
	NativeImage
))

return { create = NativeImage.new, prepare = NativeImage.prepare }
