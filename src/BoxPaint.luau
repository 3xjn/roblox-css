--!strict

local Types = require(script.Parent.Types)
local BoxModel = require(script.Parent.BoxModel)
local NativeBox = require(script.Parent.NativeBox)
local Measurements = require(script.Parent.Measurements)
local LogicalProperties = require(script.Parent.LogicalProperties)
local NativeColors = require(script.Parent.NativeColors)
local Radii = require(script.Parent.Radii)
local OutlinePaint = require(script.Parent.OutlinePaint)
local ShadowPaint = require(script.Parent.ShadowPaint)
local Transitions = require(script.Parent.Transitions)

export type Context = {
	lengths: Measurements.Context,
	currentColor: Types.RgbaColor?,
	systemColors: { [string]: Types.RgbaColor }?,
}

local BoxPaint = {}
local sides = { "top", "right", "bottom", "left" }
local currentColor: { Types.ValueToken } = { { kind = "word", value = "currentcolor" } }

local function word(tokens: { Types.ValueToken }?): string?
	return if tokens and #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

local function color(tokens: { Types.ValueToken }, context: Context): (NativeBox.Color?, string?)
	return NativeColors.resolve(tokens, { currentColor = context.currentColor, systemColors = context.systemColors })
end

local function circular(radius: Radii.Radius): number?
	if radius.x == 0 or radius.y == 0 then
		return 0
	end
	return if radius.x == radius.y then radius.x else nil
end

-- This stage owns background fill, border, outline and corners. Layout, scrolling,
-- visibility and group compositing belong to the host and their own backends.
function BoxPaint.resolve(
	style: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	geometry: BoxModel.Geometry,
	context: Context
): (NativeBox.Paint?, string?)
	local physical, mappingFailure = LogicalProperties.view(style)
	if not physical then
		return nil, mappingFailure
	end
	local properties = physical.properties
	for property in physical.unresolved do
		if
			property:sub(1, 11) == "background-"
			or property:sub(1, 7) == "border-"
			or property:sub(1, 8) == "outline-"
			or property == "box-shadow"
		then
			return nil, `{property}:{physical.unresolved[property]}`
		end
	end
	for _, property in { "background", "border-image", "border-radius", "border", "outline" } do
		if properties[property] then
			return nil, `unexpanded-paint-shorthand:{property}`
		end
	end
	for _, property in { "background-image", "border-image-source" } do
		if properties[property] and word(properties[property]) ~= "none" then
			return nil, `paint-backend-required:{property}`
		end
	end
	local transition, transitionFailure = Transitions.resolve(physical, "box-shadow")
	if transitionFailure then
		return nil, transitionFailure
	end
	local paint: NativeBox.Paint = { shadowTransition = transition }
	local shadowLayers: { ShadowPaint.Shadow } = {}
	local outer: { ShadowPaint.Shadow } = {}
	local offsetOuter = false
	if properties["box-shadow"] then
		local shadows, failure = ShadowPaint.resolve(properties["box-shadow"], context)
		if not shadows then
			return nil, failure
		end
		shadowLayers = shadows
		for _, shadow in shadows do
			if not shadow.inset then
				table.insert(outer, shadow)
				offsetOuter = offsetOuter or (shadow.color.alpha > 0 and (shadow.x ~= 0 or shadow.y ~= 0))
			end
		end
	end
	local outline, outlineFailure = OutlinePaint.resolve(physical, context)
	if outlineFailure then
		return nil, outlineFailure
	end
	paint.outline = outline
	if properties["background-color"] then
		local background, failure = color(properties["background-color"], context)
		if not background then
			return nil, `background-color:{failure or "invalid"}`
		end
		if background.transparency < 1 then
			local clipTokens = properties["background-clip"]
			local clip = if clipTokens then word(clipTokens) else "border-box"
			if not clip then
				return nil, "background-clip-list-provider-required"
			end
			if clip == "padding-box" then
				paint.backgroundBox = {
					x = metrics.border.left,
					y = metrics.border.top,
					width = geometry.width - metrics.border.left - metrics.border.right,
					height = geometry.height - metrics.border.top - metrics.border.bottom,
				}
			elseif clip == "content-box" then
				paint.backgroundBox = {
					x = geometry.contentX,
					y = geometry.contentY,
					width = geometry.contentWidth,
					height = geometry.contentHeight,
				}
			elseif clip ~= "border-box" then
				return nil, `background-clip-backend-required:{clip}`
			end
			paint.background = background
		end
	end
	local width = metrics.border.top
	local hasBorder = false
	for _, side in sides do
		if metrics.border[side] > 0 then
			hasBorder = true
		end
	end
	if hasBorder then
		local selectedColor: NativeBox.Color? = nil
		local uniform = true
		for _, side in sides do
			if metrics.border[side] ~= width then
				uniform = false
			end
			if metrics.border[side] == 0 then
				continue
			end
			local borderStyle = word(properties[`border-{side}-style`]) or "none"
			if borderStyle ~= "solid" then
				return nil, `border-style-backend-required:{borderStyle}`
			end
			local borderColor, failure = color(properties[`border-{side}-color`] or currentColor, context)
			if not borderColor then
				return nil, `border-{side}-color:{failure or "invalid"}`
			end
			if
				selectedColor
				and (selectedColor.value ~= borderColor.value or selectedColor.transparency ~= borderColor.transparency)
			then
				return nil, "nonuniform-border-color-pending"
			end
			selectedColor = borderColor
		end
		if selectedColor and selectedColor.transparency < 1 then
			if uniform then
				paint.border = { width = width, color = selectedColor }
			else
				paint.borderEdges = { widths = table.clone(metrics.border), color = selectedColor }
			end
		end
	end
	local radii, radiusFailure = Radii.resolve(physical, geometry.width, geometry.height, context.lengths)
	if not radii then
		return nil, radiusFailure
	end
	local topLeft, topRight = circular(radii.topLeft), circular(radii.topRight)
	local bottomLeft, bottomRight = circular(radii.bottomLeft), circular(radii.bottomRight)
	if topLeft == nil or topRight == nil or bottomLeft == nil or bottomRight == nil then
		return nil, "elliptical-corner-backend-required"
	end
	if topLeft > 0 or topRight > 0 or bottomLeft > 0 or bottomRight > 0 then
		paint.corners = { topLeft = topLeft, topRight = topRight, bottomLeft = bottomLeft, bottomRight = bottomRight }
	end
	local insets, insetFailure = ShadowPaint.insetRects(
		shadowLayers,
		metrics.border.left,
		metrics.border.top,
		geometry.width - metrics.border.left - metrics.border.right,
		geometry.height - metrics.border.top - metrics.border.bottom,
		paint.corners ~= nil
	)
	local function rasterFallback(failure: string?): (NativeBox.Paint?, string?)
		for _, side in { "right", "bottom", "left" } do
			if metrics.border[side] ~= metrics.border.top then
				return nil, failure
			end
		end
		paint.shadows, paint.outerShadows, paint.insetShadows = nil, nil, nil
		paint.rasterShadows = { layers = shadowLayers, border = metrics.border.top, corners = paint.corners }
		return paint, nil
	end
	if transition and (properties["transition-property"] or transition.duration + transition.delay > 0) then
		return rasterFallback("nonuniform-border-shadow-transition-provider-required")
	end
	if not insets then
		return rasterFallback(insetFailure)
	end
	paint.insetShadows = insets
	if offsetOuter then
		local rectangles, failure = ShadowPaint.outerRects(outer, geometry.width, geometry.height, paint.corners ~= nil)
		if not rectangles then
			return rasterFallback(failure)
		end
		paint.outerShadows = rectangles
	else
		local rings, failure = ShadowPaint.rings(outer)
		if not rings then
			return rasterFallback(failure)
		end
		paint.shadows = rings
	end
	return paint, nil
end

return BoxPaint
