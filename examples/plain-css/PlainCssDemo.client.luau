--!strict
-- Standalone plain CSS example (zero Tailwind, zero React, zero boilerplate).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Css = require(ReplicatedStorage.Packages.Css)
local ui = Css.create(require(ReplicatedStorage.Generated.Stylesheet))

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PlainCssDemo"
screenGui.ResetOnSpawn = false
screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local online, clicks = true, 0
local badge = ui.span("badge", { attributes = { ["data-state"] = "online" }, text = "Online" })
local counter = ui.span("badge", "Clicks: 0")

ui.div("card", {
	Parent = screenGui,
	ui.div("header", {
		ui.span("title", "Plain CSS in Roblox"),
		badge,
	}),
	ui.p("body", "Styled with ordinary CSS rules, variables, :hover/:active, and data-state — no Tailwind."),
	ui.div("actions", {
		ui.button("btn", {
			text = "Toggle status",
			onActivated = function()
				online = not online
				ui(badge, {
					attributes = { ["data-state"] = if online then "online" else "away" },
					text = if online then "Online" else "Away",
				})
			end,
		}),
		ui.button("btn btn-outline", {
			text = "Count",
			onActivated = function()
				clicks += 1
				ui(counter, { text = `Clicks: {clicks}` })
			end,
		}),
		counter,
	}),
})
