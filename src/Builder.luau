--!strict
-- Ergonomic, zero-boilerplate Luau builder on top of NativeHost.
-- Handles default fonts, hover/pointer media features, button state binding,
-- two-way class/data-*/aria-* attribute sync, and automatic cleanup.

local NativeHost = require(script.Parent.NativeHost)
local Fonts = require(script.Parent.Fonts)

export type ElementProps = {
	text: string?,
	id: string?,
	attributes: { [string]: string }?,
	states: { [string]: boolean }?,
	Parent: Instance?,
	mount: Instance?,
	onActivated: (() -> ())?,
	[number]: any,
}

export type ElementHandle = {
	tag: string,
	className: string,
	text: string?,
	id: string?,
	attributes: { [string]: string }?,
	states: { [string]: boolean }?,
	onActivated: (() -> ())?,
	children: { ElementHandle },
	gui: () -> GuiObject?,
	destroy: () -> (),
}

export type Options = {
	mergeClasses: ((...string?) -> string)?,
	primitives: any?,
	hostOptions: { [string]: any }?,
}

local function mergeClassStrings(merger: ((...string?) -> string)?, current: string, incoming: string): string
	if merger then
		return merger(current, incoming)
	end
	if current == "" then
		return incoming
	end
	if incoming == "" then
		return current
	end
	return current .. " " .. incoming
end

local function isCssAttribute(name: string): boolean
	return name == "disabled" or string.sub(name, 1, 5) == "data-" or string.sub(name, 1, 5) == "aria-"
end

local function toCssAttributeValue(value: any): string?
	if value == nil or value == false then
		return nil
	elseif value == true then
		return ""
	end
	return tostring(value)
end

local function create(stylesheet: any, options: Options?)
	assert(stylesheet ~= nil, "Css.create requires a compiled stylesheet")
	local opts = options or ({} :: Options)
	local merger = opts.mergeClasses
	local primitivesModule: any = opts.primitives

	local function resolvePrimitives(): any
		if primitivesModule == nil then
			local parent = if script and script.Parent then script.Parent.Parent else nil
			local found = if parent then parent:FindFirstChild("Primitives") else nil
			if found then
				primitivesModule = require(found :: any)
			end
		end
		return primitivesModule
	end

	local function defaultHostOptions(): { [string]: any }
		local hostOpts: { [string]: any } = if opts.hostOptions then table.clone(opts.hostOptions) else {}
		if hostOpts.nativeTextLine == nil then
			hostOpts.nativeTextLine = true
		end
		local styles: { [string]: any } = if hostOpts.styles then table.clone(hostOpts.styles) else {}
		if styles.fonts == nil then
			local fonts = Fonts.create()
			fonts:register("sans-serif", Enum.Font.BuilderSans, { ascent = 0.8, descent = 0.2 })
			fonts:register("Builder Sans", Enum.Font.BuilderSans, { ascent = 0.8, descent = 0.2 })
			fonts:register("monospace", Enum.Font.RobotoMono)
			styles.fonts = fonts
		end
		if styles.environment == nil then
			styles.environment = {
				mediaType = "screen",
				initialFontSize = 16,
				features = {
					hover = "hover",
					pointer = "fine",
					["prefers-reduced-motion"] = "no-preference",
				},
			}
		end
		hostOpts.styles = styles
		return hostOpts
	end

	local function mountTree(target: Instance?, rootElement: any): () -> ()
		local Primitives = resolvePrimitives()

		local ownedGui: ScreenGui? = nil
		local ownedMount: Frame? = nil
		local mountFrame: GuiObject

		if target == nil then
			local Players = game:GetService("Players")
			local gui = Instance.new("ScreenGui")
			gui.Name = "CssRoot"
			gui.ResetOnSpawn = false
			gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
			gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
			ownedGui = gui
			local frame = Instance.new("Frame")
			frame.Name = "CssMount"
			frame.BackgroundTransparency = 1
			frame.Size = UDim2.fromScale(1, 1)
			frame.Parent = gui
			ownedMount = frame
			mountFrame = frame
		elseif target:IsA("ScreenGui") then
			target.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
			local frame = Instance.new("Frame")
			frame.Name = "CssMount"
			frame.BackgroundTransparency = 1
			frame.Size = UDim2.fromScale(1, 1)
			frame.Parent = target
			ownedMount = frame
			mountFrame = frame
		elseif target:IsA("GuiObject") then
			mountFrame = target
		else
			error("Css mount target must be a ScreenGui, GuiObject, or nil", 2)
		end

		local host = NativeHost.create(mountFrame, stylesheet, defaultHostOptions() :: any)
		local scope = if Primitives and type(Primitives.createScope) == "function" then Primitives.createScope() else nil
		local mountedElements: { any } = {}
		local connections: { RBXScriptConnection } = {}

		local function syncAttributesToGui(elem: any)
			local guiObj = elem._gui
			if not guiObj then
				return
			end
			elem._syncingAttrs = true
			guiObj:SetAttribute("class", elem.className)
			if elem.attributes then
				for name, value in elem.attributes do
					if isCssAttribute(name) then
						guiObj:SetAttribute(name, value)
					end
				end
			end
			elem._syncingAttrs = false
		end

		local function attachNode(elem: any, parentNode: any?)
			local node = host:add({
				tag = elem.tag,
				id = elem.id,
				className = elem.className,
				attributes = elem.attributes,
				states = elem.states,
				text = elem.text,
			}, parentNode)
			elem._host = host
			elem._node = node
			elem._syncAttributes = syncAttributesToGui
			table.insert(mountedElements, elem)
			for _, child in elem.children do
				attachNode(child, node)
			end
		end

		attachNode(rootElement, nil)
		host:flushSync()

		for _, elem in mountedElements do
			local guiObj = host:getGuiObject(elem._node)
			if guiObj then
				elem._gui = guiObj
				syncAttributesToGui(elem)
				if guiObj.AttributeChanged then
					local attrConn = guiObj.AttributeChanged:Connect(function(attrName: string)
						if elem._syncingAttrs then
							return
						end
						if attrName == "class" then
							local raw = guiObj:GetAttribute("class")
							local nextClass = if type(raw) == "string" then raw else ""
							elem.className = nextClass
							host:update(elem._node, {
								tag = elem.tag,
								id = elem.id,
								className = nextClass,
								attributes = elem.attributes,
								states = elem.states,
								text = elem.text,
							})
						elseif isCssAttribute(attrName) then
							local nextVal = toCssAttributeValue(guiObj:GetAttribute(attrName))
							local attrs = elem.attributes
							if attrs == nil then
								attrs = {}
								elem.attributes = attrs
							end
							attrs[attrName] = nextVal
							host:setAttribute(elem._node, attrName, nextVal)
						end
					end)
					table.insert(connections, attrConn)
				end
				if (elem.tag == "button" or elem.onActivated ~= nil) and guiObj:IsA("GuiButton") then
					if scope then
						scope.bindButton(guiObj, {
							onState = function(state: any)
								host:setState(elem._node, "hover", state.hovered == true)
								host:setState(elem._node, "active", state.pressed == true)
								host:setState(elem._node, "focus-visible", state.focusVisible == true)
							end,
							onActivated = elem.onActivated,
						})
					elseif elem.onActivated then
						table.insert(connections, guiObj.Activated:Connect(elem.onActivated))
					end
				end
			end
		end

		local destroyed = false
		local function destroy()
			if destroyed then
				return
			end
			destroyed = true
			for _, conn in connections do
				conn:Disconnect()
			end
			table.clear(connections)
			if scope then
				scope.destroy()
			end
			host:destroy()
			if ownedMount then
				ownedMount:Destroy()
			end
			if ownedGui then
				ownedGui:Destroy()
			end
		end

		rootElement._destroy = destroy
		mountFrame.Destroying:Once(destroy)
		return destroy
	end

	local function makeElement(tag: string, className: string?, propsOrText: (string | ElementProps)?): ElementHandle
		local props: ElementProps = {}
		local text: string? = nil
		if type(propsOrText) == "string" then
			text = propsOrText
		elseif type(propsOrText) == "table" then
			props = propsOrText
			text = props.text
		end

		local children: { ElementHandle } = {}
		for index = 1, #props do
			local child = props[index]
			if child ~= nil then
				table.insert(children, child)
			end
		end

		local elem: any = {
			tag = tag,
			className = className or "",
			text = text,
			id = props.id,
			attributes = props.attributes,
			states = props.states,
			onActivated = props.onActivated,
			children = children,
			_host = nil,
			_node = nil,
			_gui = nil,
			_destroy = nil,
		}
		elem.gui = function(): GuiObject?
			if elem._host and elem._node then
				return elem._host:getGuiObject(elem._node)
			end
			return nil
		end
		elem.destroy = function()
			if elem._destroy then
				elem._destroy()
			end
		end

		local mountTarget = props.Parent or props.mount
		if mountTarget ~= nil then
			mountTree(mountTarget, elem)
		end

		return elem
	end

	local function updateElement(
		elem: any,
		update: string | { className: string?, text: string?, attributes: { [string]: string }?, states: { [string]: boolean }? },
		replaceClasses: boolean?
	)
		assert(type(elem) == "table" and elem.tag ~= nil, "Expected a Css element handle")
		local nextClass = elem.className
		local nextText = elem.text
		local nextAttributes = elem.attributes
		local nextStates = elem.states

		if type(update) == "string" then
			nextClass = if replaceClasses then update else mergeClassStrings(merger, elem.className, update)
		elseif type(update) == "table" then
			if update.className ~= nil then
				nextClass = if replaceClasses then update.className else mergeClassStrings(merger, elem.className, update.className)
			end
			if update.text ~= nil then
				nextText = update.text
			end
			if update.attributes ~= nil then
				nextAttributes = update.attributes
			end
			if update.states ~= nil then
				nextStates = update.states
			end
		end

		elem.className = nextClass
		elem.text = nextText
		elem.attributes = nextAttributes
		elem.states = nextStates

		if elem._host and elem._node then
			elem._host:update(elem._node, {
				tag = elem.tag,
				id = elem.id,
				className = nextClass,
				attributes = nextAttributes,
				states = nextStates,
				text = nextText,
			})
			if elem._syncAttributes then
				elem._syncAttributes(elem)
			end
		end
		return elem
	end

	local api: any = {
		el = makeElement,
		mount = mountTree,
		set = function(elem: any, className: string)
			return updateElement(elem, className, true)
		end,
	}

	for _, tag in { "div", "span", "p", "button", "input", "img" } do
		api[tag] = function(className: string?, propsOrText: (string | ElementProps)?)
			return makeElement(tag, className, propsOrText)
		end
	end

	return setmetatable(api, {
		__call = function(_self, elem: any, update: any)
			return updateElement(elem, update, false)
		end,
	})
end

return {
	create = create,
}
