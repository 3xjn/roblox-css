--!strict

-- CanvasGroup is Roblox's native flattened surface. Bounded clipping uses a
-- padding surface; opacity uses an expanded ink surface outside the used-size
-- layout slot. Both callers must account for its unconditional clipping.
local NativeClip = {}
NativeClip.__index = NativeClip

local available: boolean? = nil

function NativeClip.available(): boolean
	if available == nil then
		local ok, result = pcall(function()
			return Instance.new("CanvasGroup")
		end)
		available = ok
		if ok then
			(result :: CanvasGroup):Destroy()
		end
	end
	return available == true
end

local function collector(target: Instance): LayerCollector?
	return target:FindFirstAncestorWhichIsA("LayerCollector") :: LayerCollector?
end

function NativeClip.checkContext(target: Instance): (boolean, string?)
	if not NativeClip.available() then
		return false, "native-canvas-group-unavailable"
	end
	local surface = collector(target)
	if not surface then
		-- A host may be prepared before its GUI is attached. CanvasGroup can
		-- retain its clip while detached; ancestry changes revalidate the actual
		-- collector when the tree is mounted.
		return true, nil
	end
	if surface.ZIndexBehavior ~= Enum.ZIndexBehavior.Sibling then
		return false, "rounded-clip-sibling-z-order-required"
	end
	return true, nil
end

function NativeClip._refresh(self: View, notify: boolean)
	if self._destroyed then
		return
	end
	local surface = collector(self.group)
	if surface ~= self._surface then
		if self._surfaceConnection then
			self._surfaceConnection:Disconnect()
			self._surfaceConnection = nil
		end
		self._surface = surface
		if surface then
			self._surfaceConnection = surface:GetPropertyChangedSignal("ZIndexBehavior"):Connect(function()
				self:_refresh(true)
			end)
		end
	end
	local eligible, failure = NativeClip.checkContext(self.group)
	local changed = eligible ~= self._eligible
	self._eligible = eligible
	self.group.Visible = eligible
	if self._destroyed then
		return
	end
	if failure ~= self._failure then
		self._failure = failure
		if failure and self._onDiagnostic then
			self._onDiagnostic(failure)
		end
	end
	if not self._destroyed and notify and changed and self._onContextChanged then
		self._onContextChanged()
	end
end

function NativeClip.new(parent: GuiObject, onDiagnostic: ((string) -> ())?, onContextChanged: (() -> ())?): View
	local group = Instance.new("CanvasGroup")
	group.Name = "CssRoundedClip"
	group.BackgroundTransparency = 1
	group.BorderSizePixel = 0
	group.Size = UDim2.fromScale(1, 1)
	group.GroupTransparency = 0
	group.GroupColor3 = Color3.new(1, 1, 1)
	group.Visible = false
	group.Active = false
	group.Selectable = false
	local corner = Instance.new("UICorner")
	corner.Name = "ClipCorners"
	corner.CornerRadius = UDim.new()
	corner.Parent = group
	local self: View = setmetatable({
		group = group,
		corner = corner,
		_destroyed = false,
		_eligible = false,
		_surface = nil :: LayerCollector?,
		_surfaceConnection = nil :: RBXScriptConnection?,
		_connections = {} :: { RBXScriptConnection },
		_failure = nil :: string?,
		_onDiagnostic = onDiagnostic,
		_onContextChanged = onContextChanged,
	}, NativeClip)
	table.insert(
		self._connections,
		group.Destroying:Connect(function()
			self:_release()
		end)
	)
	group.Parent = parent
	self:_refresh(false)
	if not self._destroyed then
		table.insert(
			self._connections,
			group.AncestryChanged:Connect(function()
				self:_refresh(true)
			end)
		)
	end
	return self
end

function NativeClip.apply(self: View, radii: { [string]: UDim }, individual: boolean): (boolean, string?)
	if self._destroyed then
		return false, "native-clip-destroyed"
	end
	self:_refresh(false)
	if self._destroyed or not self._eligible then
		return false, self._failure or "native-clip-context-unavailable"
	end
	self.corner.CornerRadius = radii.topLeft
	if individual then
		if self._destroyed then
			return false, "native-clip-destroyed"
		end
		self.corner.TopLeftRadius = radii.topLeft
		if self._destroyed then
			return false, "native-clip-destroyed"
		end
		self.corner.TopRightRadius = radii.topRight
		if self._destroyed then
			return false, "native-clip-destroyed"
		end
		self.corner.BottomLeftRadius = radii.bottomLeft
		if self._destroyed then
			return false, "native-clip-destroyed"
		end
		self.corner.BottomRightRadius = radii.bottomRight
	end
	return not self._destroyed, if self._destroyed then "native-clip-destroyed" else nil
end

function NativeClip._release(self: View)
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self._surfaceConnection then
		self._surfaceConnection:Disconnect()
		self._surfaceConnection = nil
	end
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._surface = nil
	self._onDiagnostic = nil
	self._onContextChanged = nil
end

-- The owner reparents surviving content before removing this private group.
function NativeClip.destroy(self: View)
	if self._destroyed then
		return
	end
	self:_release()
	self.group:Destroy()
end

export type View = typeof(setmetatable(
	{} :: {
		group: CanvasGroup,
		corner: UICorner,
		_destroyed: boolean,
		_eligible: boolean,
		_surface: LayerCollector?,
		_surfaceConnection: RBXScriptConnection?,
		_connections: { RBXScriptConnection },
		_failure: string?,
		_onDiagnostic: ((string) -> ())?,
		_onContextChanged: (() -> ())?,
	},
	NativeClip
))

return { create = NativeClip.new, available = NativeClip.available, checkContext = NativeClip.checkContext }
