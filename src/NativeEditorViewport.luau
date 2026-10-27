--!strict

local GlyphStyle = require(script.Parent.GlyphStyle)
local NativeDimensions = require(script.Parent.NativeDimensions)

local NativeEditorViewport = {}
NativeEditorViewport.__index = NativeEditorViewport

-- Keep the native TextBox wide enough for its text, so its private horizontal
-- scroll does not reset the visible range on blur. The CSS content frame clips
-- and places that one editor. No text copy is painted over the native control.
function NativeEditorViewport.create(box: TextBox, clip: Frame, hitSurface: GuiObject): View
	clip.ClipsDescendants = true
	local self = setmetatable({
		box = box,
		clip = clip,
		_width = 0,
		_height = 0,
		_offset = 0,
		_enabled = false,
		_glyph = nil :: GlyphStyle.Style?,
		_measure = nil :: TextLabel?,
		_measureGlyph = nil :: GlyphStyle.Style?,
		_measureLineHeight = 0,
		_pending = false,
		_destroyed = false,
		_connections = {} :: { RBXScriptConnection },
	}, NativeEditorViewport)
	local function changed()
		self:_schedule()
	end
	for _, property in { "Text", "TextBounds", "CursorPosition" } do
		table.insert(self._connections, box:GetPropertyChangedSignal(property):Connect(changed))
	end
	table.insert(self._connections, box.Focused:Connect(changed))
	table.insert(self._connections, box.FocusLost:Connect(changed))
	-- The native editor is clipped to the content area. Forward padding clicks
	-- from its own paint box, gated by the behavior binding's native flags.
	table.insert(
		self._connections,
		hitSurface.InputBegan:Connect(function(input)
			if
				not self._destroyed
				and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
				and box.Active
				and box.Interactable
				and box.GuiState ~= Enum.GuiState.NonInteractable
				and not box:IsFocused()
			then
				box:CaptureFocus()
			end
		end)
	)
	return self
end

function NativeEditorViewport._prefixWidth(self: View, cursor: number): number
	local text = self.box.Text
	if cursor <= 1 then
		return 0
	elseif cursor > #text then
		return self.box.TextBounds.X
	end
	local measure = self._measure
	if not measure then
		measure = Instance.new("TextLabel")
		measure.Name = "CssEditorCaretMeasure"
		measure.Visible, measure.Active, measure.Selectable, measure.Interactable = false, false, false, false
		measure.AutoLocalize, measure.RichText, measure.TextScaled, measure.TextWrapped = false, false, false, false
		measure.AutomaticSize = Enum.AutomaticSize.None
		measure.Size = UDim2.fromOffset(1000000, 1000)
		measure.TextTruncate = Enum.TextTruncate.None
		measure.BackgroundTransparency, measure.BorderSizePixel = 1, 0
		measure.Parent = self.clip
		self._measure = measure
		table.insert(
			self._connections,
			measure:GetPropertyChangedSignal("TextBounds"):Connect(function()
				self:_schedule()
			end)
		)
	end
	local label = assert(measure)
	local glyph = assert(self._glyph)
	local previous = self._measureGlyph
	if
		not previous
		or previous.font.Family ~= glyph.font.Family
		or previous.font.Weight ~= glyph.font.Weight
		or previous.font.Style ~= glyph.font.Style
	then
		label.FontFace = self.box.FontFace
	end
	if not previous or previous.size ~= glyph.size then
		label.TextSize = glyph.size
	end
	if self._measureLineHeight ~= self.box.LineHeight then
		label.LineHeight = self.box.LineHeight
	end
	if not previous or previous.direction ~= glyph.direction then
		label.TextDirection = self.box.TextDirection
	end
	if (not previous and glyph.features ~= "") or (previous and previous.features ~= glyph.features) then
		pcall(function() label.OpenTypeFeatures = glyph.features end)
	end
	self._measureGlyph, self._measureLineHeight = glyph, self.box.LineHeight
	local prefix = text:sub(1, cursor - 1)
	if label.Text ~= prefix then
		label.Text = prefix
	end
	return label.TextBounds.X
end

function NativeEditorViewport._refresh(self: View)
	if self._destroyed then
		return
	end
	local box, width = self.box, self._width
	if not self._enabled or width <= 0 then
		self._offset = 0
		box.Position, box.Size = UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1)
		return
	end
	local extent = math.max(width, box.TextBounds.X + 1)
	local limit = extent - width
	local offset = math.clamp(self._offset, 0, limit)
	local cursor = box.CursorPosition
	if limit > 0 and box:IsFocused() and cursor >= 1 then
		local caret = self:_prefixWidth(cursor)
		if caret < offset then
			offset = caret
		elseif caret + 1 > offset + width then
			offset = caret + 1 - width
		end
	end
	offset = math.clamp(offset, 0, limit)
	self._offset = offset
	local position = NativeDimensions.pair(-offset, 0, Vector2.new(width, self._height))
	assert(position, "Native editor viewport offset is not representable")
	local size = if limit == 0 then UDim2.fromScale(1, 1) else UDim2.new(0, extent, 1, 0)
	if box.Size ~= size then
		box.Size = size
	end
	if not self._destroyed and box.Position ~= position then
		box.Position = position
	end
end

function NativeEditorViewport._schedule(self: View)
	if self._destroyed or self._pending then
		return
	end
	self._pending = true
	task.defer(function()
		self._pending = false
		self:_refresh()
	end)
end

function NativeEditorViewport.apply(
	self: View,
	width: number,
	height: number,
	enabled: boolean,
	glyph: GlyphStyle.Style
)
	self._width, self._height, self._enabled, self._glyph = width, height, enabled, glyph
	self:_refresh()
end

function NativeEditorViewport.destroy(self: View)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	if self._measure then
		self._measure:Destroy()
		self._measure = nil
	end
	self._glyph = nil
	self._measureGlyph = nil
end

export type View = typeof(setmetatable(
	{} :: {
		box: TextBox,
		clip: Frame,
		_width: number,
		_height: number,
		_offset: number,
		_enabled: boolean,
		_glyph: GlyphStyle.Style?,
		_measure: TextLabel?,
		_measureGlyph: GlyphStyle.Style?,
		_measureLineHeight: number,
		_pending: boolean,
		_destroyed: boolean,
		_connections: { RBXScriptConnection },
	},
	NativeEditorViewport
))

return NativeEditorViewport
