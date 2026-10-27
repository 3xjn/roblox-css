--!strict

local Types = require(script.Parent.Types)
local ListLayout = require(script.Parent.ListLayout)
local NativeDimensions = require(script.Parent.NativeDimensions)
type Listener = () -> ()
type Saved = {
	position: UDim2,
	size: UDim2,
	anchor: Vector2,
	automaticSize: Enum.AutomaticSize,
	order: number,
	flex: UIFlexItem?,
	connections: { RBXScriptConnection },
}

type ChildKind = "gui" | "flex" | "constraint" | "layout" | "padding" | "other"
-- Class inheritance is immutable during an engine session. Cache class facts,
-- never child membership: every apply still inspects the current children.
local childKinds: { [string]: ChildKind } = {}
local function childKind(child: Instance): ChildKind
	local name = child.ClassName
	local cached = childKinds[name]
	if cached then
		return cached
	end
	local kind: ChildKind = if child:IsA("GuiObject")
		then "gui"
		elseif child:IsA("UIFlexItem") then "flex"
		elseif child:IsA("UISizeConstraint") or child:IsA("UIAspectRatioConstraint") or child:IsA("UIScale") then "constraint"
		elseif child:IsA("UILayout") then "layout"
		elseif child:IsA("UIPadding") then "padding"
		else "other"
	childKinds[name] = kind
	return kind
end

local NativeList = {}
NativeList.__index = NativeList

local function notify(self: Layout)
	if self._destroyed or self._pending then
		return
	end
	self._pending = true
	task.defer(function()
		self._pending = false
		if self._destroyed then
			return
		end
		for listener in table.clone(self._listeners) do
			if self._destroyed then
				break
			end
			if self._listeners[listener] then
				listener()
			end
		end
	end)
end

local function restore(self: Layout, frame: GuiObject, saved: Saved, restoreProperties: boolean)
	if saved.flex then
		saved.flex:Destroy()
		saved.flex = nil
	end
	for _, connection in saved.connections do
		connection:Disconnect()
	end
	if restoreProperties and frame.Parent == self.container then
		frame.Position = saved.position
		frame.Size = saved.size
		frame.AnchorPoint = saved.anchor
		frame.AutomaticSize = saved.automaticSize
		frame.LayoutOrder = saved.order
	end
end

function NativeList.new(container: GuiObject): Layout
	local layout = Instance.new("UIListLayout")
	layout.Name = "CssListLayout"
	local supported = pcall(function()
		layout.HorizontalFlex = Enum.UIFlexAlignment.None
		layout.VerticalFlex = Enum.UIFlexAlignment.None
		layout.ItemLineAlignment = Enum.ItemLineAlignment.Automatic
		layout.Wraps = false
	end)
	local flex: UIFlexItem? = nil
	local itemAlignment = pcall(function()
		local probe = Instance.new("UIFlexItem")
		flex = probe
		probe.FlexMode = Enum.UIFlexMode.None
		probe.ItemLineAlignment = Enum.ItemLineAlignment.Start
	end)
	if flex then
		flex:Destroy()
	end
	local self = setmetatable({
		container = container,
		layout = layout,
		_supported = supported,
		_itemAlignment = itemAlignment,
		_destroyed = false,
		_pending = false,
		_items = {} :: { [GuiObject]: Saved },
		_listeners = {} :: { [Listener]: boolean },
		_connections = {} :: { RBXScriptConnection },
	}, NativeList)
	table.insert(
		self._connections,
		layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			notify(self)
		end)
	)
	table.insert(
		self._connections,
		container:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			notify(self)
		end)
	)
	table.insert(
		self._connections,
		container.Destroying:Connect(function()
			self:_release(false)
		end)
	)
	return self
end

local horizontal: { [string]: Enum.HorizontalAlignment } = {
	start = Enum.HorizontalAlignment.Left,
	center = Enum.HorizontalAlignment.Center,
	["end"] = Enum.HorizontalAlignment.Right,
}
local vertical: { [string]: Enum.VerticalAlignment } = {
	start = Enum.VerticalAlignment.Top,
	center = Enum.VerticalAlignment.Center,
	["end"] = Enum.VerticalAlignment.Bottom,
}
local itemAlignments: { [string]: Enum.ItemLineAlignment } = {
	start = Enum.ItemLineAlignment.Start,
	center = Enum.ItemLineAlignment.Center,
	["end"] = Enum.ItemLineAlignment.End,
}
local function alignmentMode(plan: ListLayout.Plan, available: boolean): (boolean?, string?)
	if plan.manual then
		return nil, "native-list-margin-placement-provider-required"
	end
	local mixed = false
	for _, item in plan.items do
		if item.margins then
			return nil, "native-list-margin-placement-provider-required"
		end
		local alignment = item.crossAlign or plan.crossAlign
		if not itemAlignments[alignment] then
			return nil, "invalid-list-item-alignment"
		end
		mixed = mixed or alignment ~= plan.crossAlign
	end
	if mixed and not available then
		return nil, "native-item-alignment-unavailable"
	end
	if mixed then
		for _, item in plan.items do
			if if plan.horizontal then item.height > plan.height else item.width > plan.width then
				return nil, "mixed-cross-overflow-provider-required"
			end
		end
	end
	return mixed, nil
end
local function distributed(name: string): Enum.UIFlexAlignment?
	if name == "space-between" then
		return Enum.UIFlexAlignment.SpaceBetween
	end
	if name == "space-around" then
		return Enum.UIFlexAlignment.SpaceAround
	end
	if name == "space-evenly" then
		return Enum.UIFlexAlignment.SpaceEvenly
	end
	return nil
end

-- The container is exclusively managed by this adapter. Items remain caller-
-- owned, but this attachment owns their placement, size, anchor and order until
-- detached. Decorative layers belong outside this content container.
function NativeList.apply(self: Layout, plan: ListLayout.Plan, views: { [Types.Node]: GuiObject }): (boolean, string?)
	if self._destroyed then
		return false, "list-layout-destroyed"
	end
	if not self._supported then
		return false, "native-list-controls-unavailable"
	end
	if
		plan.width < 0
		or plan.height < 0
		or plan.width ~= plan.width
		or plan.height ~= plan.height
		or plan.width == math.huge
		or plan.height == math.huge
	then
		return false, "invalid-list-content-size"
	end
	if plan.gap < 0 or plan.gap ~= plan.gap or plan.gap == math.huge then
		return false, "invalid-list-gap"
	end
	local mainHorizontal = horizontal[plan.mainAlign]
	local mainVertical = vertical[plan.mainAlign]
	if plan.mainAlign == "space-between" and #plan.items <= 1 then
		mainHorizontal = horizontal[plan.mainStart or "start"]
		mainVertical = vertical[plan.mainStart or "start"]
	end
	local crossHorizontal = horizontal[plan.crossAlign]
	local crossVertical = vertical[plan.crossAlign]
	local distribution = distributed(plan.mainAlign)
	if (not mainHorizontal and not distribution) or not crossHorizontal then
		return false, "invalid-list-alignment"
	end
	if self.container.AutomaticSize ~= Enum.AutomaticSize.None then
		return false, "definite-list-container-required"
	end
	-- A successfully encoded size also marks a selected view. Keep validation
	-- and placement on one call-local map, including during reentrant calls.
	local sizes: { [GuiObject]: UDim2 } = {}
	local mixed, alignmentFailure = alignmentMode(plan, self._itemAlignment)
	if mixed == nil then
		return false, alignmentFailure
	end
	local gap, gapFailure = NativeDimensions.axis(plan.gap, if plan.horizontal then plan.width else plan.height)
	if not gap then
		return false, gapFailure
	end
	for _, item in plan.items do
		local frame = views[item.node]
		if not frame or frame.Parent ~= self.container then
			return false, "list-item-parent-mismatch"
		end
		if sizes[frame] then
			return false, "duplicate-list-view"
		end
		if
			item.width < 0
			or item.height < 0
			or item.width ~= item.width
			or item.height ~= item.height
			or item.width == math.huge
			or item.height == math.huge
		then
			return false, "invalid-used-item-size"
		end
		if not frame.Visible or frame.Rotation ~= 0 then
			return false, "visible-unrotated-layout-carrier-required"
		end
		local saved = self._items[frame]
		for _, child in frame:GetChildren() do
			local kind = childKind(child)
			if
				(kind == "flex" and (not saved or child ~= saved.flex))
				or kind == "constraint"
			then
				return false, "list-item-sizing-ownership-conflict"
			end
		end
		local size, sizeFailure = NativeDimensions.pair(item.width, item.height, Vector2.new(plan.width, plan.height))
		if not size then
			return false, sizeFailure
		end
		sizes[frame] = size
	end
	for _, child in self.container:GetChildren() do
		local kind = childKind(child)
		if kind == "gui" and not sizes[child :: GuiObject] then
			return false, "unregistered-list-child"
		end
		if (kind == "layout" and child ~= self.layout) or kind == "padding" then
			return false, "list-container-layout-ownership-conflict"
		end
	end
	local fillDirection = if plan.horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	local horizontalFlex = if plan.horizontal
		then (distribution or Enum.UIFlexAlignment.None)
		else (if mixed then Enum.UIFlexAlignment.Fill else Enum.UIFlexAlignment.None)
	local verticalFlex = if not plan.horizontal
		then (distribution or Enum.UIFlexAlignment.None)
		else (if mixed then Enum.UIFlexAlignment.Fill else Enum.UIFlexAlignment.None)
	local horizontalAlignment = if plan.horizontal
		then (mainHorizontal or Enum.HorizontalAlignment.Left)
		else crossHorizontal
	local verticalAlignment = if plan.horizontal then crossVertical else (mainVertical or Enum.VerticalAlignment.Top)
	local unchanged = self.layout.Parent == self.container
		and self.layout.FillDirection == fillDirection
		and self.layout.SortOrder == Enum.SortOrder.LayoutOrder
		and self.layout.Padding == gap
		and not self.layout.Wraps
		and self.layout.ItemLineAlignment == Enum.ItemLineAlignment.Automatic
		and self.layout.HorizontalFlex == horizontalFlex
		and self.layout.VerticalFlex == verticalFlex
		and self.layout.HorizontalAlignment == horizontalAlignment
		and self.layout.VerticalAlignment == verticalAlignment
	for frame in self._items do
		if not sizes[frame] then
			unchanged = false
		end
	end
	for index, item in plan.items do
		local frame = views[item.node]
		local saved = self._items[frame]
		if
			not saved
			or frame.Size ~= sizes[frame]
			or frame.AnchorPoint ~= Vector2.zero
			or frame.AutomaticSize ~= Enum.AutomaticSize.None
			or frame.LayoutOrder ~= index
		then
			unchanged = false
		elseif mixed then
			local flex = saved.flex
			if
				not flex
				or flex.Parent ~= frame
				or flex.FlexMode ~= Enum.UIFlexMode.None
				or flex.ItemLineAlignment ~= itemAlignments[item.crossAlign or plan.crossAlign]
			then
				unchanged = false
			end
		elseif saved.flex then
			unchanged = false
		end
	end
	-- Keep validation above even for an identical plan: external ownership
	-- conflicts must still fail. Avoid detaching a live layout just to rewrite
	-- the same properties and trigger another round of geometry notifications.
	if unchanged then
		return true, nil
	end
	-- Validate before touching caller-owned objects, then commit without yielding.
	self.layout.Parent = nil
	for frame, saved in self._items do
		if not sizes[frame] then
			restore(self, frame, saved, true)
			self._items[frame] = nil
		end
	end
	for index, item in plan.items do
		local frame = views[item.node]
		if not self._items[frame] then
			local saved: Saved = {
				position = frame.Position,
				size = frame.Size,
				anchor = frame.AnchorPoint,
				automaticSize = frame.AutomaticSize,
				order = frame.LayoutOrder,
				flex = nil,
				connections = {},
			}
			self._items[frame] = saved
			table.insert(
				saved.connections,
				frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
					notify(self)
				end)
			)
			table.insert(
				saved.connections,
				frame:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
					notify(self)
				end)
			)
			table.insert(
				saved.connections,
				frame.Destroying:Connect(function()
					if self._items[frame] == saved then
						self._items[frame] = nil
						restore(self, frame, saved, false)
						notify(self)
					end
				end)
			)
			table.insert(
				saved.connections,
				frame.AncestryChanged:Connect(function()
					if frame.Parent ~= self.container and self._items[frame] == saved then
						self._items[frame] = nil
						restore(self, frame, saved, false)
						notify(self)
					end
				end)
			)
		end
		local saved = self._items[frame]
		if mixed then
			local flex = saved.flex or Instance.new("UIFlexItem")
			flex.Name = "CssItemAlignment"
			-- CSS sizing already resolved grow/shrink, min/max and stretch.
			-- The native component owns placement only, not another size solve.
			flex.FlexMode = Enum.UIFlexMode.None
			flex.ItemLineAlignment = itemAlignments[item.crossAlign or plan.crossAlign]
			flex.Parent = frame
			saved.flex = flex
		elseif saved.flex then
			saved.flex:Destroy()
			saved.flex = nil
		end
		frame.AnchorPoint = Vector2.zero
		frame.AutomaticSize = Enum.AutomaticSize.None
		frame.Size = sizes[frame]
		frame.LayoutOrder = index
	end
	self.layout.FillDirection = fillDirection
	self.layout.SortOrder = Enum.SortOrder.LayoutOrder
	self.layout.Padding = gap
	self.layout.Wraps = false
	self.layout.ItemLineAlignment = Enum.ItemLineAlignment.Automatic
	self.layout.HorizontalFlex = horizontalFlex
	self.layout.VerticalFlex = verticalFlex
	self.layout.HorizontalAlignment = horizontalAlignment
	self.layout.VerticalAlignment = verticalAlignment
	self.layout.Parent = self.container
	return true, nil
end

function NativeList.subscribe(self: Layout, listener: Listener): () -> ()
	assert(not self._destroyed, "List layout has been destroyed")
	self._listeners[listener] = true
	return function()
		self._listeners[listener] = nil
	end
end

function NativeList.isSupported(self: Layout, plan: ListLayout.Plan?): (boolean, string?)
	if self._destroyed or not self._supported then
		return false, "native-list-controls-unavailable"
	end
	if plan then
		local mode, failure = alignmentMode(plan, self._itemAlignment)
		return mode ~= nil, failure
	end
	return true, nil
end

function NativeList._release(self: Layout, restoreProperties: boolean)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self.layout:Destroy()
	for frame, saved in self._items do
		restore(self, frame, saved, restoreProperties)
	end
	table.clear(self._items)
	table.clear(self._listeners)
end

function NativeList.destroy(self: Layout)
	self:_release(true)
end

export type Layout = typeof(setmetatable(
	{} :: {
		container: GuiObject,
		layout: UIListLayout,
		_supported: boolean,
		_itemAlignment: boolean,
		_destroyed: boolean,
		_pending: boolean,
		_items: { [GuiObject]: Saved },
		_listeners: { [Listener]: boolean },
		_connections: { RBXScriptConnection },
	},
	NativeList
))

return { create = NativeList.new }
