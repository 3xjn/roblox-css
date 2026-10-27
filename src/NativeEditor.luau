--!strict

local Types = require(script.Parent.Types)
local GlyphStyle = require(script.Parent.GlyphStyle)
local Typography = require(script.Parent.Typography)
local BoxModel = require(script.Parent.BoxModel)
local NativeDimensions = require(script.Parent.NativeDimensions)
local TextContent = require(script.Parent.TextContent)
local Measurements = require(script.Parent.Measurements)
local NativeText = require(script.Parent.NativeText)
local NativeEditorViewport = require(script.Parent.NativeEditorViewport)

export type Data = { value: string?, defaultValue: string?, placeholder: string?, multiline: boolean? }
export type Prepared = {
	data: Data,
	glyph: GlyphStyle.Style,
	lineHeight: number,
	alignment: Enum.TextXAlignment,
	padding: { left: UDim, right: UDim, top: UDim, bottom: UDim },
	placeholderColor: Color3?,
	placeholderOverlay: { glyph: GlyphStyle.Style, width: number, height: number }?,
	viewport: { width: number, height: number },
}

local NativeEditor = {}
NativeEditor.__index = NativeEditor

local function word(style: Types.ComputedStyle, property: string, fallback: string): string?
	local tokens = style.properties[property]
	if not tokens then
		return fallback
	end
	return if #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

function NativeEditor.prepare(
	style: Types.ComputedStyle,
	glyph: GlyphStyle.Style,
	data: Data,
	geometry: BoxModel.Geometry,
	placeholder: Types.ComputedStyle?,
	placeholderGlyph: GlyphStyle.Style?
): (Prepared?, string?)
	if glyph.size <= 0 then
		return nil, "native-editor-positive-font-size-required"
	end
	for _, property in { "line-height", "text-align", "text-indent", "text-transform", "text-decoration-line" } do
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
	end
	local defaults: { [string]: string } = { ["text-transform"] = "none", ["text-decoration-line"] = "none" }
	for property, fallback in defaults do
		if word(style, property, fallback) ~= fallback then
			return nil, `native-editor-style-provider-required:{property}`
		end
	end
	local indent = style.properties["text-indent"]
	if
		indent
		and (
			#indent ~= 1
			or (indent[1].kind ~= "number" and indent[1].kind ~= "dimension")
			or tonumber(indent[1].value) ~= 0
		)
	then
		return nil, "native-editor-text-indent-provider-required"
	end
	local alignment = word(style, "text-align", "start")
	if alignment == "start" then
		alignment = if glyph.direction == "rtl" then "right" else "left"
	end
	if alignment == "end" then
		alignment = if glyph.direction == "rtl" then "left" else "right"
	end
	local alignments =
		{ left = Enum.TextXAlignment.Left, right = Enum.TextXAlignment.Right, center = Enum.TextXAlignment.Center }
	local nativeAlignment = if alignment then alignments[alignment] else nil
	if not nativeAlignment then
		return nil, "native-editor-text-align-provider-required"
	end
	local lineHeight = 1
	if word(style, "line-height", "normal") ~= "normal" then
		local resolved = Typography.lineHeight(style)
		if not resolved then
			return nil, "native-editor-computed-line-height-required"
		end
		lineHeight = resolved / glyph.size
	end
	if lineHeight < 1 or lineHeight > 3 then
		return nil, "native-editor-line-height-out-of-range"
	end
	for _, value in { data.value or "", data.defaultValue or "", data.placeholder or "" } do
		if not utf8.len(value) then
			return nil, "invalid-editor-text-utf8"
		end
		if not data.multiline then
			local failure = TextContent.validateSingleLine(value)
			if failure then
				return nil, failure
			end
		end
	end
	local left, a = NativeDimensions.axis(geometry.contentX, geometry.width)
	local top, b = NativeDimensions.axis(geometry.contentY, geometry.height)
	local right, c = NativeDimensions.axis(geometry.width - geometry.contentX - geometry.contentWidth, geometry.width)
	local bottom, d =
		NativeDimensions.axis(geometry.height - geometry.contentY - geometry.contentHeight, geometry.height)
	if not left or not top or not right or not bottom then
		return nil, a or b or c or d
	end
	local placeholderColor: Color3? = nil
	local placeholderOverlay = nil
	if placeholder then
		if not placeholderGlyph then
			return nil, "placeholder-glyph-style-required"
		end
		for property in placeholder.priorities do
			local supported = property == "color"
				or property == "opacity"
				or property == "direction"
				or property:sub(1, 5) == "font-"
				or property == "letter-spacing"
				or property == "word-spacing"
			if not supported then
				return nil, `native-placeholder-property-provider-required:{property}`
			end
			if placeholder.unresolved[property] then
				return nil, placeholder.unresolved[property]
			end
		end
		local shape = placeholderGlyph
		if
			shape.font.Family ~= glyph.font.Family
			or shape.font.Weight ~= glyph.font.Weight
			or shape.font.Style ~= glyph.font.Style
			or shape.size ~= glyph.size
			or shape.features ~= glyph.features
			or shape.direction ~= glyph.direction
		then
			return nil, "native-placeholder-independent-font-provider-required"
		end
		local opacity = 1
		if placeholder.properties.opacity then
			local value, failure =
				Measurements.resolve(placeholder.properties.opacity, { percentageDimension = "number" })
			if not value or value.dimension ~= "number" then
				return nil, failure or "invalid-placeholder-opacity"
			end
			opacity = math.clamp(value.value, 0, 1)
		end
		local transparency = 1 - (1 - shape.color.transparency) * opacity
		if math.abs(transparency - glyph.color.transparency) > 1e-6 then
			local overlayGlyph = table.clone(shape)
			overlayGlyph.color = { value = shape.color.value, transparency = transparency }
			placeholderOverlay =
				{ glyph = overlayGlyph, width = geometry.contentWidth, height = geometry.contentHeight }
		end
		if placeholder.priorities.color then
			placeholderColor = shape.color.value
		end
	end
	return {
		data = table.clone(data),
		glyph = glyph,
		lineHeight = lineHeight,
		alignment = nativeAlignment,
		padding = { left = left, right = right, top = top, bottom = bottom },
		placeholderColor = placeholderColor,
		placeholderOverlay = placeholderOverlay,
		viewport = { width = geometry.contentWidth, height = geometry.contentHeight },
	},
		nil
end

function NativeEditor.new(box: TextBox, onDiagnostic: ((string) -> ())?, clip: Frame?, hitSurface: GuiObject?): View
	box.AutoLocalize, box.RichText, box.TextScaled = false, false, false
	box.ClearTextOnFocus = false
	box.ClipsDescendants = true
	box.TextTruncate = Enum.TextTruncate.None
	box.MaxVisibleGraphemes = -1
	box.TextStrokeTransparency = 1
	local padding = Instance.new("UIPadding")
	padding.Name = "EditorPadding"
	padding.Parent = box
	-- TextBox feature support varies by engine and font; keep native editing usable.
	local self = setmetatable({
		box = box,
		padding = padding,
		_initialized = false,
		_placeholderColor = box.PlaceholderColor3,
		_placeholder = nil :: NativeText.View?,
		_placeholderClip = nil :: Frame?,
		_onDiagnostic = onDiagnostic,
		_destroyed = false,
		_connections = {} :: { RBXScriptConnection },
		_viewport = if clip and hitSurface
			then NativeEditorViewport.create(box, clip, hitSurface)
			else nil :: NativeEditorViewport.View?,
	}, NativeEditor)
	table.insert(
		self._connections,
		box:GetPropertyChangedSignal("Text"):Connect(function()
			self:_refreshPlaceholder()
		end)
	)
	table.insert(
		self._connections,
		box:GetPropertyChangedSignal("ZIndex"):Connect(function()
			self:_refreshPlaceholder()
		end)
	)
	table.insert(
		self._connections,
		box.Destroying:Connect(function()
			self:destroy()
		end)
	)

	return self
end

function NativeEditor._refreshPlaceholder(self: View)
	local label = if self._placeholder then self._placeholder.label else nil
	if self._destroyed or not label then
		return
	end
	label.Visible = self.box.Text == "" and label.Text ~= ""
	label.ZIndex = self.box.ZIndex
	if self._placeholderClip then
		self._placeholderClip.ZIndex = self.box.ZIndex
	end
end

function NativeEditor._removePlaceholder(self: View)
	if self._placeholder then
		self._placeholder:destroy()
		self._placeholder = nil
	end
	if self._placeholderClip then
		self._placeholderClip:Destroy()
		self._placeholderClip = nil
	end
end

function NativeEditor.apply(self: View, prepared: Prepared): (boolean, string?)
	if self._destroyed then
		return false, "native-editor-destroyed"
	end
	local box, glyph, data = self.box, prepared.glyph, prepared.data

	box.TextSize = glyph.size
	if self._destroyed then
		return false, "native-editor-destroyed"
	end
	if math.abs(box.TextSize - glyph.size) > math.max(1, glyph.size) * 1e-6 then
		return false, "native-editor-text-size-not-representable"
	end
	box.FontFace = Font.new(glyph.font.Family, glyph.font.Weight, glyph.font.Style)
	box.TextColor3, box.TextTransparency = glyph.color.value, glyph.color.transparency
	box.TextDirection = if glyph.direction == "rtl"
		then Enum.TextDirection.RightToLeft
		else Enum.TextDirection.LeftToRight
	box.TextXAlignment = prepared.alignment
	box.TextYAlignment = if data.multiline then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center
	box.LineHeight = prepared.lineHeight
	box.MultiLine, box.TextWrapped = data.multiline == true, data.multiline == true
	local overlay = prepared.placeholderOverlay
	if overlay and data.placeholder and data.placeholder ~= "" then
		local view = self._placeholder
		if not view then
			local clip = Instance.new("Frame")
			clip.Name = "CssPlaceholderClip"
			clip.BackgroundTransparency, clip.BorderSizePixel = 1, 0
			clip.Position, clip.Size = UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1)
			clip.Active, clip.Selectable, clip.Interactable, clip.ClipsDescendants = false, false, false, true
			-- Native UIPadding already places children in the editing area.
			-- The manually positioned CSS content frame would double the inset.
			self._placeholderClip = clip
			clip.Parent = box
			if self._destroyed then
				return false, "native-editor-destroyed"
			end
			view = NativeText.create(clip, self._onDiagnostic)
			if self._destroyed then
				view:destroy()
				return false, "native-editor-destroyed"
			end
			view.label.Name = "CssPlaceholder"
			view.label.Interactable = false
			self._placeholder = view
		end
		local placeholderView = assert(view)
		local applied, failure = placeholderView:apply(
			data.placeholder,
			overlay.width,
			overlay.height,
			overlay.glyph,
			Vector2.new(overlay.width, overlay.height),
			nil,
			if data.multiline then "top" else "center",
			data.multiline == true
		)
		if not applied then
			return false, failure
		end
		placeholderView.label.TextXAlignment = prepared.alignment
		placeholderView.label.LineHeight = prepared.lineHeight
		box.PlaceholderText = ""
	else
		self:_removePlaceholder()
		box.PlaceholderText = data.placeholder or ""
	end
	box.PlaceholderColor3 = prepared.placeholderColor or self._placeholderColor
	if self._destroyed then
		return false, "native-editor-destroyed"
	end
	-- A scene's content frame already supplies its border/padding inset. The
	-- independent font probe has no such frame and retains native UIPadding.
	local viewport = self._viewport
	self.padding.PaddingLeft = if viewport then UDim.new() else prepared.padding.left
	self.padding.PaddingRight = if viewport then UDim.new() else prepared.padding.right
	self.padding.PaddingTop = if viewport then UDim.new() else prepared.padding.top
	self.padding.PaddingBottom = if viewport then UDim.new() else prepared.padding.bottom
	local wanted = data.value or (if not self._initialized then data.defaultValue or "" else nil)
	self._initialized = true
	-- Text stays native-owned in uncontrolled mode; an identical controlled echo
	-- never performs a Text write that could disturb selection/composition.
	if wanted ~= nil and box.Text ~= wanted then
		box.Text = wanted
	end
	if viewport then
		viewport:apply(
			prepared.viewport.width,
			prepared.viewport.height,
			data.multiline ~= true and prepared.alignment == Enum.TextXAlignment.Left and glyph.direction == "ltr",
			glyph
		)
	end
	self:_refreshPlaceholder()
	return not self._destroyed, if self._destroyed then "native-editor-destroyed" else nil
end

function NativeEditor.destroy(self: View)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	if self._viewport then
		self._viewport:destroy()
		self._viewport = nil
	end
	self:_removePlaceholder()
	self._onDiagnostic = nil
	self.padding:Destroy()
end

export type View = typeof(setmetatable(
	{} :: {
		box: TextBox,
		padding: UIPadding,
		_initialized: boolean,
		_placeholderColor: Color3,
		_placeholder: NativeText.View?,
		_placeholderClip: Frame?,
		_onDiagnostic: ((string) -> ())?,
		_destroyed: boolean,
		_connections: { RBXScriptConnection },
		_viewport: NativeEditorViewport.View?,
	},
	NativeEditor
))

return NativeEditor
