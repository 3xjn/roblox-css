--!strict

local TextMeasurement = require(script.Parent.TextMeasurement)
local NativeText = require(script.Parent.NativeText)

local NativeTextMeasurement = {}
local function discardDiagnostic(_failure: string) end
local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

-- GetTextBoundsParams cannot carry OpenType features or text direction. Use
-- the same native glyph view for those requests, on an unscaled hidden surface.
-- Ordinary LTR requests retain the TextService path without creating a view.
function NativeTextMeasurement.create(parent: GuiObject): TextMeasurement.Backend
	local destroyed = false
	local generation = 0
	local frames: { [Frame]: boolean } = {}
	local listeners: { [() -> ()]: boolean } = {}
	local connection: RBXScriptConnection? = nil
	local collector: LayerCollector? = nil
	local function surface(): LayerCollector?
		local ancestor = parent:FindFirstAncestorWhichIsA("LayerCollector")
		return if ancestor and ancestor:IsDescendantOf(game) then ancestor :: LayerCollector else nil
	end
	local function clear()
		generation += 1
		local previous = frames
		frames = {}
		for frame in previous do
			frame:Destroy()
		end
	end
	local function changed()
		local current = surface()
		if destroyed or current == collector then
			return
		end
		collector = current
		if next(listeners) == nil then
			clear()
		else
			for listener in table.clone(listeners) do
				if listeners[listener] and not destroyed then
					listener()
				end
			end
		end
	end
	local function observe()
		if not connection then
			collector = surface()
			connection = parent.AncestryChanged:Connect(changed)
		else
			changed()
		end
	end
	local function measureAsync(value: TextMeasurement.Request): (Vector2?, string?)
		if destroyed then
			return nil, "native-text-measurement-backend-destroyed"
		end
		if value.features == "" and value.direction == "ltr" then
			local revision = generation
			local bounds, failure = TextMeasurement.measureAsync(value)
			if destroyed or generation ~= revision then
				return nil, "stale-native-text-measurement"
			end
			return bounds, failure
		end
		observe()
		local revision = generation
		-- Warm the exact face and fallback characters; these unfeatured bounds
		-- are never returned as the answer to a feature-shaped request.
		local warm, failure = TextMeasurement.measureAsync({
			text = value.text,
			font = value.font,
			size = value.size,
			features = "",
			direction = "ltr",
		})
		if not warm then
			return nil, failure
		end
		if destroyed or generation ~= revision then
			return nil, "stale-native-text-measurement"
		end
		if value.text == "" or value.size == 0 then
			return Vector2.zero, nil
		end
		local target = surface()
		if not target then
			return nil, "native-feature-measurement-live-collector-required"
		end
		local preference = game:GetService("GuiService").PreferredTextSize
		local frame = Instance.new("Frame")
		frame.Name = "CssTextMeasurement"
		frame.Visible = false
		frame.Active = false
		frame.Selectable = false
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Size = UDim2.fromOffset(0, 0)
		frames[frame] = true
		local view: NativeText.View? = nil
		local ok, bounds, reason = pcall(function(): (Vector2?, string?)
			-- A direct collector child excludes the target's UIScales. Dividing
			-- scaled bounds is incorrect because native glyph hinting changes.
			frame.Parent = target
			if destroyed or generation ~= revision then
				return nil, "stale-native-text-measurement"
			end
			local glyph = NativeText.create(frame, discardDiagnostic)
			view = glyph
			local applied, applyFailure = glyph:apply(value.text, 0, 0, {
				font = value.font,
				size = value.size,
				features = value.features,
				direction = value.direction,
				color = { value = Color3.new(), transparency = 0 },
			})
			if not applied then
				return nil, applyFailure
			end
			-- Reading bounds forces native shaping. A previously empty view can
			-- report its feature error only after that work, not on assignment.
			local measured = glyph.label.TextBounds
			if value.features ~= "" then
				local featureFailure = glyph.label.OpenTypeFeaturesError
				if featureFailure ~= "" then
					return nil, `native-opentype-features:{featureFailure}`
				end
			end
			if not finite(measured.X) or not finite(measured.Y) or measured.X < 0 or measured.Y <= 0 then
				return nil, "native-feature-text-bounds-unavailable"
			end
			return measured, nil
		end)
		if view then
			view:destroy()
		end
		frames[frame] = nil
		frame:Destroy()
		if destroyed or generation ~= revision or game:GetService("GuiService").PreferredTextSize ~= preference then
			return nil, "stale-native-text-measurement"
		end
		if not ok then
			return nil, `native-feature-text-measurement:{tostring(bounds)}`
		end
		return bounds, reason
	end
	return {
		measureAsync = measureAsync,
		clear = clear,
		subscribe = function(listener)
			assert(not destroyed, "Native text measurement backend has been destroyed")
			listeners[listener] = true
			return function()
				listeners[listener] = nil
			end
		end,
		destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			clear()
			if connection then
				connection:Disconnect()
				connection = nil
			end
			table.clear(listeners)
		end,
	}
end

return NativeTextMeasurement
