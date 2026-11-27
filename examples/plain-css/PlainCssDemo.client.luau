--!strict
-- Standalone plain CSS example (zero Tailwind, zero React).
-- Uses @3xjn/roblox-css + @3xjn/roblox-primitives with a compiled styles.css.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Css = require(ReplicatedStorage.Packages.Css)
local Primitives = require(ReplicatedStorage.Packages.Primitives)
local Stylesheet = require(ReplicatedStorage.Generated.Stylesheet)

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PlainCssDemo"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local mount = Instance.new("Frame")
mount.BackgroundTransparency = 1
mount.Size = UDim2.fromOffset(360, 220)
mount.Position = UDim2.fromOffset(24, 24)
mount.Parent = screenGui

local fonts = Css.createFontProvider()
fonts:register("sans-serif", Enum.Font.BuilderSans, { ascent = 0.8, descent = 0.2 })
fonts:register("Builder Sans", Enum.Font.BuilderSans, { ascent = 0.8, descent = 0.2 })

local host = Css.createHost(mount, Stylesheet, {
	nativeTextLine = true,
	styles = {
		fonts = fonts,
		environment = {
			mediaType = "screen",
			initialFontSize = 16,
			features = { hover = "hover", pointer = "fine", ["prefers-reduced-motion"] = "no-preference" },
		},
	},
})
local input = Primitives.createScope()

local card = host:add({ tag = "div", className = "card" })
local header = host:add({ tag = "div", className = "header" }, card)
host:add({ tag = "span", className = "title", text = "Plain CSS in Roblox" }, header)

local online = true
local badge = host:add({
	tag = "span",
	className = "badge",
	attributes = { ["data-state"] = "online" },
	text = "Online",
}, header)

host:add({
	tag = "p",
	className = "body",
	text = "Styled with ordinary CSS rules, variables, :hover/:active, and data-state selectors — no Tailwind.",
}, card)

local actions = host:add({ tag = "div", className = "actions" }, card)
local toggleBtn = host:add({ tag = "button", className = "btn", text = "Toggle status" }, actions)
local countBtn = host:add({ tag = "button", className = "btn btn-outline", text = "Count" }, actions)
local clicks = 0
local counter = host:add({ tag = "span", className = "badge", text = "Clicks: 0" }, actions)

host:flushSync()

local function bind(node: any, onActivated: () -> ())
	local gui = host:getGuiObject(node)
	if gui and gui:IsA("GuiButton") then
		input.bindButton(gui, {
			onState = function(state)
				host:setState(node, "hover", state.hovered)
				host:setState(node, "active", state.pressed)
				host:setState(node, "focus-visible", state.focusVisible)
			end,
			onActivated = onActivated,
		})
	end
end

bind(toggleBtn, function()
	online = not online
	host:setAttribute(badge, "data-state", if online then "online" else "away")
	host:update(badge, {
		tag = "span",
		className = "badge",
		attributes = { ["data-state"] = if online then "online" else "away" },
		text = if online then "Online" else "Away",
	})
end)

bind(countBtn, function()
	clicks += 1
	host:update(counter, {
		tag = "span",
		className = "badge",
		text = `Clicks: {clicks}`,
	})
end)

screenGui.Destroying:Once(function()
	input.destroy()
	host:destroy()
end)
