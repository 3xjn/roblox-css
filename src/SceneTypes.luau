--!strict

local Types = require(script.Parent.Types)
local BoxModel = require(script.Parent.BoxModel)
local Measurements = require(script.Parent.Measurements)
local ListLayout = require(script.Parent.ListLayout)
local TextMeasurement = require(script.Parent.TextMeasurement)
local NativeBox = require(script.Parent.NativeBox)
local NativeEditor = require(script.Parent.NativeEditor)
local NativeImage = require(script.Parent.NativeImage)
local SceneAnimations = require(script.Parent.SceneAnimations)
local SceneTransforms = require(script.Parent.SceneTransforms)

-- A logical node can own multiple render fragments. Render parentage is
-- explicit and independent of CSS inheritance (e.g. portals/inline fragments).
export type Key = Types.Node | string | number
export type RunKey = string | number
-- Offsets from the owning border-box top. A missing set means no in-flow
-- baseline; a present set with a missing edge means that edge is unmeasured.
-- Unknown native text baselines must not trigger empty-box synthesis.
export type Baselines = { first: number?, last: number? }
export type GlyphRun = {
	key: RunKey?,
	source: Types.Node?,
	owner: Types.Node?,
	text: string,
	x: number,
	y: number,
	width: number,
	height: number,
	zIndex: number?,
	-- Explicit native paint policy; not an automatic CSS text-overflow map.
	truncate: ("none" | "split-word")?,
	verticalAlign: ("top" | "center")?,
}
export type Box = {
	node: Types.Node,
	owner: Types.Node?,
	kind: NativeBox.Kind?,
	editor: NativeEditor.Data?,
	image: NativeImage.Data?,
	-- Same content coordinates, outside the parent's native list layout.
	outOfFlow: boolean?,
	parent: Key?,
	x: number,
	y: number,
	width: number,
	height: number,
	metrics: BoxModel.Metrics,
	-- Visual translation after layout; list carriers retain the unshifted slot.
	offsetX: number?,
	offsetY: number?,
	lengths: Measurements.Context,
	baselines: Baselines?,
	runs: { GlyphRun }?,
	zIndex: number?,
	paintZIndex: number?,
}
export type List = { plan: ListLayout.Plan, views: { [Types.Node]: Key } }
export type Plan = { boxes: { [Key]: Box }, lists: { [Key]: List }?, styles: { [Types.Node]: Types.ComputedStyle }? }
export type Snapshot = {
	revision: number,
	-- Default-host epoch for non-style geometry inputs. Omission disables
	-- layout reuse; custom providers need not participate in this contract.
	layoutRevision: number?,
	roots: { Types.Node },
	styles: { [Types.Node]: Types.ComputedStyle },
	viewport: Vector2,
	initialFontSize: number?,
	measureText: TextMeasurement.Reader?,
	anonymousStyle: ((Types.Node) -> (Types.ComputedStyle?, string?))?,
	pseudoStyle: ((Types.Node, string) -> Types.ComputedStyle?)?,
	-- Optional formatting projection; logical parent/children remain unchanged.
	boxChildren: ((Types.Node) -> ({ Types.Node }?, string?))?,
	-- Native glyph bounds from the last committed scene, not CSS line boxes.
	measurements: { [Key]: { [RunKey]: Vector2 } },
	animations: { [Types.Node]: SceneAnimations.Data }?,
	-- Formatters materialize generated boxes after the public styles resolve.
	-- Resolve their effects with the originating element's cascade context.
	animation: ((Types.Node, Types.ComputedStyle, Types.Node?, string?) -> (SceneAnimations.Data?, string?))?,
	transformTransitions: { [Types.Node]: SceneTransforms.Requirement }?,
	transformTransition: ((Types.Node, Types.ComputedStyle) -> (SceneTransforms.Requirement?, string?))?,
}
export type Provider = (Snapshot) -> (Plan?, string?)

return {}
