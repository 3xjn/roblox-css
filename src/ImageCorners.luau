--!strict

local BoxModel = require(script.Parent.BoxModel)
local InsetCorners = require(script.Parent.InsetCorners)

export type Corners = InsetCorners.Corners
export type Context = { geometry: BoxModel.Geometry, corners: Corners?, perCornerRadius: boolean? }
export type Encoded = InsetCorners.Encoded

local ImageCorners = {}
local diagnostics = {
	["invalid-inset-clip-geometry"] = "invalid-image-clip-geometry",
	["invalid-inset-clip-radius"] = "invalid-image-clip-radius",
	["elliptical-inset-clip-provider-required"] = "elliptical-image-content-clip-provider-required",
	["native-inset-radius-clamping-differs"] = "native-image-radius-clamping-differs",
	["native-inset-per-corner-radius-unavailable"] = "native-image-per-corner-radius-unavailable",
}

function ImageCorners.resolve(context: Context): (Encoded?, string?)
	local geometry = context.geometry
	local result, failure = InsetCorners.resolve({
		width = geometry.width,
		height = geometry.height,
		x = geometry.contentX,
		y = geometry.contentY,
		innerWidth = geometry.contentWidth,
		innerHeight = geometry.contentHeight,
		corners = context.corners,
		perCornerRadius = context.perCornerRadius,
	})
	return result, if failure then diagnostics[failure] or failure else nil
end

return ImageCorners
