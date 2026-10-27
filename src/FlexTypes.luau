--!strict

local Types = require(script.Parent.Types)
local BoxModel = require(script.Parent.BoxModel)
local Measurements = require(script.Parent.Measurements)
local AspectRatio = require(script.Parent.AspectRatio)

export type Mode = "undefined" | "exactly" | "at-most"
export type Constraints = { width: number?, height: number?, widthMode: Mode, heightMode: Mode }
export type Size = { width: number, height: number }
export type Measure = (Constraints) -> (Size?, string?)
export type Intrinsic = {
	-- Resolved CSS automatic minimums, in border-box logical pixels. The host
	-- owns any additional intrinsic/replaced contributions. Explicit values
	-- remain authoritative over the frontend's derived ratio suggestions.
	autoMinWidth: number?,
	autoMinHeight: number?,
	-- Raw non-replaced min-content suggestions, before preferred/max-size caps.
	minContentWidth: number?,
	maxContentWidth: number?,
	minContentHeight: number?,
	measure: Measure?,
	-- Needed when an automatic/content basis cannot be derived from a definite
	-- preferred main size. This is the measured outer CSS flex base, before min/
	-- max clamping or flooring the content size to zero.
	flexBase: number?,
	hypotheticalCrossSize: number?,
}
export type Item = Intrinsic & {
	node: Types.Node,
	style: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	-- Replaced-resource ratio suggestions require a separate intrinsic model.
	replaced: boolean?,
	lengths: Measurements.Context?,
	-- The sizing frontend decides whether inline contributions are needed.
	-- Explicit supplied intrinsic fields remain authoritative over this result.
	resolveIntrinsic: ((inlineSizeRequired: boolean) -> (Intrinsic?, string?))?,
}
export type Context = {
	-- Placement remains normal-flow; the owning scene supplies relative paint.
	relativePositioning: boolean?,
	width: number,
	height: number,
	lengths: Measurements.Context,
	-- Intrinsic preparation may have a numeric scratch width without a CSS
	-- percentage basis. Used layout still requires a resolved inline size.
	widthDefinite: boolean?,
	-- Numeric used height and percentage-basis definiteness are independent.
	heightDefinite: boolean?,
	-- Multi-line rows measure each natural line against the container's
	-- percentage basis, independently of that line's final used height.
	measureCross: boolean?,
	percentageHeightBasis: number?,
	-- Rows derive a cross height; columns derive a main height before flexing.
	autoHeight: boolean?,
	minHeight: number?,
	maxHeight: number?,
}
export type PreparedItem = {
	ratio: AspectRatio.Ratio?,
	node: Types.Node,
	metrics: BoxModel.Metrics,
	width: number?,
	height: number?,
	minWidth: number,
	minHeight: number,
	maxWidth: number?,
	maxHeight: number?,
	grow: number,
	shrink: number,
	basis: number?,
	mainDefinite: boolean?,
	alignSelf: string,
	measure: Measure?,
	flexBase: number?,
	hypotheticalCrossSize: number?,
}
export type Prepared = {
	width: number,
	height: number,
	direction: string,
	flow: string,
	alignItems: string,
	gap: number,
	items: { PreparedItem },
	autoCross: boolean?,
	autoMain: boolean?,
	minimumMain: number?,
	maximumMain: number?,
	minimumCross: number?,
	maximumCross: number?,
}
export type UsedItem = {
	node: Types.Node,
	width: number,
	height: number,
	widthDefinite: boolean,
	heightDefinite: boolean,
}

return {}
