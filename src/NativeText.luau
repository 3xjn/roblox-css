--!strict

local GlyphStyle = require(script.Parent.GlyphStyle)
local NativeDimensions = require(script.Parent.NativeDimensions)
local TextMeasurement = require(script.Parent.TextMeasurement)
local TextContent = require(script.Parent.TextContent)
local TextDecoration = require(script.Parent.TextDecoration)
export type BoundsListener = (Vector2) -> ()

local NativeText = {}
NativeText.__index = NativeText

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function sameFont(a: Font, b: Font): boolean
	return a.Family == b.Family and a.Weight == b.Weight and a.Style == b.Style
end

local function sameDecoration(a: TextDecoration.Decoration?, b: TextDecoration.Decoration?): boolean
	return a == b or (a ~= nil and b ~= nil and a.underline == b.underline and a.strike == b.strike)
end

local function scheduleBounds(self: View)
	if self._destroyed or self._pendingBounds then
		return
	end
	self._pendingBounds = true
	task.defer(function()
		self._pendingBounds = false
		if self._destroyed then
			return
		end
		local bounds = self.label.TextBounds
		if self._lastBounds == bounds then
			return
		end
		self._lastBounds = bounds
		for listener in table.clone(self._listeners) do
			if self._destroyed then
				break
			end
			if self._listeners[listener] then
				listener(bounds)
			end
		end
	end)
end

function NativeText.new(parent: Instance, onDiagnostic: ((string) -> ())?): View
	local label = Instance.new("TextLabel")
	label.Name = "CssGlyphRun"
	label.AnchorPoint = Vector2.zero
	label.Position = UDim2.fromOffset(0, 0)
	label.Size = UDim2.fromOffset(0, 0)
	label.AutomaticSize = Enum.AutomaticSize.None
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.ClipsDescendants = false
	label.Active = false
	label.Selectable = false
	label.AutoLocalize = false
	label.RichText = false
	label.Text = ""
	label.TextSize = 16
	label.TextScaled = false
	label.TextWrapped = false
	label.TextTruncate = Enum.TextTruncate.None
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextDirection = Enum.TextDirection.LeftToRight
	label.LineHeight = 1
	label.MaxVisibleGraphemes = -1
	label.TextStrokeTransparency = 1
	label.Visible = false
	local hasSplitTruncate = pcall(function()
		label.TextTruncate = Enum.TextTruncate.SplitWord
	end)
	label.TextTruncate = Enum.TextTruncate.None
	local hasFeatures = pcall(function()
		label.OpenTypeFeatures = ""
		local _error = label.OpenTypeFeaturesError
	end)
	local self = setmetatable({
		label = label,
		_hasFeatures = hasFeatures,
		_hasSplitTruncate = hasSplitTruncate,
		_destroyed = false,
		_generation = 0,
		_pendingBounds = false,
		_pendingFeatureError = false,
		_onDiagnostic = onDiagnostic,
		_lastBounds = nil :: Vector2?,
		_style = nil :: GlyphStyle.Style?,
		_text = "",
		_renderedText = nil :: string?,
		_listeners = {} :: { [BoundsListener]: boolean },
		_connections = {} :: { RBXScriptConnection },
	}, NativeText)
	table.insert(
		self._connections,
		label:GetPropertyChangedSignal("TextBounds"):Connect(function()
			scheduleBounds(self)
		end)
	)
	table.insert(
		self._connections,
		label.Destroying:Connect(function()
			self:_release()
		end)
	)
	if hasFeatures then
		table.insert(
			self._connections,
			label:GetPropertyChangedSignal("OpenTypeFeaturesError"):Connect(function()
				if self._pendingFeatureError or self._destroyed then
					return
				end
				self._pendingFeatureError = true
				task.defer(function()
					self._pendingFeatureError = false
					if self._destroyed then
						return
					end
					local failure = label.OpenTypeFeaturesError
					if failure ~= "" then
						if self._onDiagnostic then
							self._onDiagnostic(`native-opentype-features:{failure}`)
						else
							warn(`[roblox-css:native-opentype-features] {failure}`)
						end
					end
				end)
			end)
		)
	end
	label.Parent = parent
	return self
end

-- Render one already laid-out line. The line layout provider owns whitespace,
-- wrapping, alignment and baseline placement. A TextLabel never wraps it again.
function NativeText.apply(
	self: View,
	text: string,
	width: number,
	height: number,
	style: GlyphStyle.Style,
	reference: Vector2?,
	truncate: ("none" | "split-word")?,
	verticalAlign: ("top" | "center")?,
	multiline: boolean?
): (boolean, string?)
	if self._destroyed then
		return false, "text-view-destroyed"
	end
	if verticalAlign and verticalAlign ~= "top" and verticalAlign ~= "center" then
		return false, "invalid-native-glyph-vertical-alignment"
	end
	if truncate ~= nil and truncate ~= "none" and truncate ~= "split-word" then
		return false, "unsupported-native-glyph-truncation"
	elseif truncate == "split-word" and not self._hasSplitTruncate then
		return false, "native-split-word-truncation-unavailable"
	end
	if not finite(width) or not finite(height) or width < 0 or height < 0 then
		return false, "invalid-text-geometry"
	end
	local size, sizeFailure = NativeDimensions.pair(width, height, reference)
	if not size then
		return false, sizeFailure
	end
	local nativeSize = if style.size == 0 then 1 else style.size
	local direction = if style.direction == "rtl"
		then Enum.TextDirection.RightToLeft
		else Enum.TextDirection.LeftToRight
	local truncation = if truncate == "split-word" then Enum.TextTruncate.SplitWord else Enum.TextTruncate.None
	local alignment = if verticalAlign == "center" then Enum.TextYAlignment.Center else Enum.TextYAlignment.Top
	local previous = self._style
	-- Compare owned snapshots and current native properties. Equal caller table
	-- identities alone cannot prove that mutable requests or the label stayed put.
	-- Matching successful snapshots also preserves their content/style validation.
	if
		previous
		and self._renderedText ~= nil
		and self._text == text
		and previous.size == style.size
		and previous.features == style.features
		and (style.features == "" or self._hasFeatures)
		and previous.direction == style.direction
		and previous.color.value == style.color.value
		and previous.color.transparency == style.color.transparency
		and self.label.Size == size
		and self.label.Text == self._renderedText
		and self.label.TextTruncate == truncation
		and self.label.TextYAlignment == alignment
		and self.label.TextWrapped == (multiline == true)
		and sameFont(previous.font, style.font)
		and sameDecoration(previous.decoration, style.decoration)
		and self.label.TextSize == nativeSize
		and sameFont(self.label.FontFace, style.font)
		and self.label.TextColor3 == style.color.value
		and self.label.TextTransparency == style.color.transparency
		and self.label.TextDirection == direction
		and self.label.RichText == (style.decoration ~= nil)
		and self.label.Visible
		and (
			not self._hasFeatures
			or (self.label.OpenTypeFeatures == style.features and self.label.OpenTypeFeaturesError == "")
		)
	then
		-- Retain the public per-apply stale-measurement and bounds contracts.
		self._generation += 1
		scheduleBounds(self)
		return true, nil
	end
	local contentFailure = if multiline then nil else TextContent.validateSingleLine(text)
	if contentFailure then
		return false, contentFailure
	end
	if not finite(style.size) or style.size < 0 then
		return false, "invalid-text-size"
	end
	if style.direction ~= "ltr" and style.direction ~= "rtl" then
		return false, "invalid-text-direction"
	end
	for _, channel in { style.color.value.R, style.color.value.G, style.color.value.B, style.color.transparency } do
		if not finite(channel) or channel < 0 or channel > 1 then
			return false, "invalid-text-color"
		end
	end
	if style.features ~= "" and not self._hasFeatures then
		return false, "native-opentype-features-unavailable"
	end
	local previousFeatures = if self._hasFeatures then self.label.OpenTypeFeatures else ""
	if self._hasFeatures then
		self.label.OpenTypeFeatures = style.features
		local failure = self.label.OpenTypeFeaturesError
		if failure ~= "" then
			self.label.OpenTypeFeatures = previousFeatures
			return false, `native-opentype-features:{failure}`
		end
	end
	local previousSize = self.label.TextSize
	local sizeOk = pcall(function()
		self.label.TextSize = nativeSize
	end)
	if not sizeOk or math.abs(self.label.TextSize - nativeSize) > math.max(1, nativeSize) * 1e-6 then
		self.label.TextSize = previousSize
		if self._hasFeatures then
			self.label.OpenTypeFeatures = previousFeatures
		end
		return false, "native-text-size-not-representable"
	end
	local font = Font.new(style.font.Family, style.font.Weight, style.font.Style)
	self._renderedText = nil
	self._generation += 1
	self._text = text
	self._style = {
		font = font,
		size = if style.size == 0 then 0 else self.label.TextSize,
		color = table.clone(style.color),
		features = style.features,
		direction = style.direction,
		decoration = if style.decoration then table.clone(style.decoration) else nil,
	}
	self.label.FontFace = font
	self.label.TextColor3 = style.color.value
	self.label.TextTransparency = style.color.transparency
	self.label.TextDirection = direction
	self.label.Size = size
	self.label.TextTruncate = truncation
	self.label.TextYAlignment = alignment
	self.label.TextWrapped = multiline == true
	self.label.RichText = style.decoration ~= nil
	local renderedText = if style.size == 0 or text == ""
		then ""
		elseif style.decoration then TextDecoration.markup(text, style.decoration)
		else text
	self.label.Text = renderedText
	self.label.Visible = true
	if not self._destroyed then
		self._renderedText = renderedText
	end
	scheduleBounds(self)
	return true, nil
end

function NativeText.subscribeBounds(self: View, listener: BoundsListener): () -> ()
	assert(not self._destroyed, "Text view has been destroyed")
	self._listeners[listener] = true
	return function()
		self._listeners[listener] = nil
	end
end

-- Native shaping bounds, not a CSS line box or baseline measurement. Feature-
-- shaped text must use the view's TextBounds event: GetTextBoundsParams has no
-- feature setting. Stale results are rejected after any apply or disposal.
function NativeText.measureAsync(self: View): (Vector2?, string?)
	if self._destroyed then
		return nil, "text-view-destroyed"
	end
	local style = self._style
	if not style then
		return nil, "text-view-not-applied"
	end
	if style.size == 0 or self._text == "" then
		return Vector2.zero, nil
	end
	local generation = self._generation
	local bounds, failure = TextMeasurement.measureAsync({
		text = self._text,
		font = Font.new(style.font.Family, style.font.Weight, style.font.Style),
		size = style.size,
		features = style.features,
		direction = style.direction,
	})
	if self._destroyed or generation ~= self._generation then
		return nil, "stale-text-measurement"
	end
	return bounds, failure
end

function NativeText._release(self: View)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._generation += 1
	self._style = nil
	self._renderedText = nil
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	table.clear(self._listeners)
end

function NativeText.destroy(self: View)
	if self._destroyed then
		return
	end
	self:_release()
	self.label:Destroy()
end

export type View = typeof(setmetatable(
	{} :: {
		label: TextLabel,
		_hasFeatures: boolean,
		_hasSplitTruncate: boolean,
		_destroyed: boolean,
		_generation: number,
		_pendingBounds: boolean,
		_pendingFeatureError: boolean,
		_onDiagnostic: ((string) -> ())?,
		_lastBounds: Vector2?,
		_style: GlyphStyle.Style?,
		_text: string,
		_renderedText: string?,
		_listeners: { [BoundsListener]: boolean },
		_connections: { RBXScriptConnection },
	},
	NativeText
))

return { create = NativeText.new }
