--!strict

local Types = require(script.Parent.Types)
local Display = require(script.Parent.Display)
local SceneTypes = require(script.Parent.SceneTypes)
local BoxModel = require(script.Parent.BoxModel)
local BoxPaint = require(script.Parent.BoxPaint)
local NativeBox = require(script.Parent.NativeBox)
local NativeDimensions = require(script.Parent.NativeDimensions)
local GlyphStyle = require(script.Parent.GlyphStyle)
local Fonts = require(script.Parent.Fonts)
local Colors = require(script.Parent.Colors)
local Measurements = require(script.Parent.Measurements)
local TextContent = require(script.Parent.TextContent)
local NativeEditor = require(script.Parent.NativeEditor)
local NativeImage = require(script.Parent.NativeImage)
local TranslationTransform = require(script.Parent.Transform2D)
local Transitions = require(script.Parent.Transitions)
local SceneAnimations = require(script.Parent.SceneAnimations)
local AnimationValues = require(script.Parent.AnimationValues)
local FormattingFragments = require(script.Parent.FormattingFragments)
local WorkQueue = require(script.Parent.WorkQueue)
local SceneDependencies = require(script.Parent.SceneDependencies)
local SceneTransforms = require(script.Parent.SceneTransforms)

export type Run = {
	key: SceneTypes.RunKey,
	source: Types.Node,
	owner: Types.Node,
	text: string,
	position: UDim2,
	width: number,
	height: number,
	style: GlyphStyle.Style,
	zIndex: number,
	truncate: ("none" | "split-word")?,
	verticalAlign: ("top" | "center")?,
}
export type Box = {
	source: SceneTypes.Box,
	kind: NativeBox.Kind,
	pointerBlocked: boolean,
	visible: boolean,
	hiddenNativeAncestor: boolean,
	geometry: BoxModel.Geometry,
	position: UDim2,
	reference: Vector2,
	offsetX: number,
	offsetY: number,
	transformContext: boolean,
	intrinsicTransformContext: boolean,
	transformTransition: SceneTransforms.Requirement?,
	rotation: number,
	scale: number,
	roundedClip: boolean,
	layoutCarrier: boolean,
	carrierOffset: UDim2?,
	paint: NativeBox.Paint,
	nativePaint: NativeBox.Prepared,
	opacity: number,
	opacitySurface: boolean,
	opacityTransition: Transitions.Config?,
	runs: { Run },
	editor: NativeEditor.Prepared?,
	image: NativeImage.Prepared?,
	animation: SceneAnimations.Data?,
	animationModel: AnimationValues.Model?,
}
export type Prepared = {
	order: { SceneTypes.Key },
	boxes: { [SceneTypes.Key]: Box },
	lists: { [SceneTypes.Key]: SceneTypes.List },
}
type ColorResult = { value: Types.RgbaColor?, failure: string? }
type PreparedEffects = {
	paint: NativeBox.Paint,
	opacity: number,
	opacityTransition: Transitions.Config?,
	replacedImage: boolean,
}
type PaintEntry = {
	revision: number,
	style: Types.ComputedStyle,
	width: number,
	height: number,
	color: Types.RgbaColor?,
	paint: NativeBox.Paint,
	nativePaint: NativeBox.Prepared?,
	nativeReference: Vector2?,
	nativeReplacedImage: boolean?,
	effects: PreparedEffects?,
}
export type PaintCache = { [SceneTypes.Box]: PaintEntry }
type GlyphEntry = { revision: number, inheritedColor: Types.RgbaColor?, glyph: GlyphStyle.Style }
export type GlyphCache = { [Types.ComputedStyle]: GlyphEntry }

type BoxEntry = {
	base: Box,
	paint: PaintEntry?,
	dependencies: { SceneDependencies.Path }?,
	disabled: boolean,
	nativeControl: ("auto" | "button")?,
	parentHidden: boolean,
	placeholder: Types.ComputedStyle?,
}
export type BoxCache = {
	token: {},
	revision: number,
	fonts: Fonts.Provider,
	systemColors: { [string]: Types.RgbaColor }?,
	entries: { [SceneTypes.Box]: BoxEntry },
	fragments: { [{}]: BoxEntry }?,
	keys: { [SceneTypes.Key]: BoxEntry }?,
	dependencies: SceneDependencies.Paths?,
}

-- A retained fragment certifies metrics, lengths, text/editor data and runs.
-- Its caller can still place/reparent/rank the resulting boxes. Those fields
-- must match before the old native base can be retained across scene layouts.
local function samePlacement(a: SceneTypes.Box, b: SceneTypes.Box): boolean
	return a.node == b.node
		and a.owner == b.owner
		and a.kind == b.kind
		and a.outOfFlow == b.outOfFlow
		and a.parent == b.parent
		and a.x == b.x
		and a.y == b.y
		and a.width == b.width
		and a.height == b.height
		and a.offsetX == b.offsetX
		and a.offsetY == b.offsetY
		and a.zIndex == b.zIndex
		and a.paintZIndex == b.paintZIndex
		and a.image == nil
		and b.image == nil
end

local function sameValue(a: unknown, b: unknown): boolean
	if a ~= b then
		return false
	end
	-- Signed zero can affect CSS math even when ordinary numeric equality holds.
	return type(a) ~= "number" or a ~= 0 or (type(b) == "number" and 1 / a == 1 / b)
end

local function sameRecord(a: { [string]: unknown }, b: { [string]: unknown }): boolean
	for name, value in a do
		if not sameValue(value, b[name]) then
			return false
		end
	end
	for name in b do
		if a[name] == nil then
			return false
		end
	end
	return true
end

local function sameLengths(a: Measurements.Context, b: Measurements.Context): boolean
	local before, after = a :: { [string]: unknown }, b :: { [string]: unknown }
	for name, value in before do
		local other = after[name]
		if sameValue(value, other) then
			continue
		end
		if
			(name == "units" or name == "mathRange")
			and type(value) == "table"
			and type(other) == "table"
			and sameRecord(value :: { [string]: unknown }, other :: { [string]: unknown })
		then
			continue
		end
		return false
	end
	for name in after do
		if before[name] == nil then
			return false
		end
	end
	return true
end

-- Paint reads border widths, used geometry and calculation units. A successful
-- default-host commit owns the old source; placement, text and descendants do
-- not enter this smaller proof. Unstamped/custom scenes never use it.
local function samePaintInputs(previous: Box, source: SceneTypes.Box, geometry: BoxModel.Geometry): boolean
	return previous.source.node == source.node
		and sameRecord(
			previous.source.metrics.border :: { [string]: unknown },
			source.metrics.border :: { [string]: unknown }
		)
		and sameRecord(previous.geometry :: { [string]: unknown }, geometry :: { [string]: unknown })
		and sameLengths(previous.source.lengths, source.lengths)
end

local function sameData(a: unknown, b: unknown): boolean
	if sameValue(a, b) then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	local before, after = a :: { [unknown]: unknown }, b :: { [unknown]: unknown }
	for name, value in before do
		if not sameData(value, after[name]) then
			return false
		end
	end
	for name in after do
		if before[name] == nil then
			return false
		end
	end
	return true
end

-- These fields contain owned scalar geometry/setup data. Other fields retain
-- identity comparisons, including logical owners, keys and future additions.
local sourceData = { metrics = true, lengths = true, baselines = true, editor = true }
local function sameSource(a: SceneTypes.Box, b: SceneTypes.Box): boolean
	if not samePlacement(a, b) then
		return false
	end
	local before, after = a :: { [string]: unknown }, b :: { [string]: unknown }
	for name, value in before do
		local current = after[name]
		if sameValue(value, current) then
			continue
		end
		if sourceData[name] then
			if not sameData(value, current) then
				return false
			end
		elseif name == "runs" and type(value) == "table" and type(current) == "table" then
			local oldRuns, newRuns = value :: { [unknown]: unknown }, current :: { [unknown]: unknown }
			for key, run in oldRuns do
				local nextRun = newRuns[key]
				if sameValue(run, nextRun) then
					continue
				end
				-- Run source/owner/key tables are identities, never structural data.
				if
					type(run) ~= "table"
					or type(nextRun) ~= "table"
					or not sameRecord(run :: { [string]: unknown }, nextRun :: { [string]: unknown })
				then
					return false
				end
			end
			for key in newRuns do
				if oldRuns[key] == nil then
					return false
				end
			end
		else
			return false
		end
	end
	for name in after do
		if before[name] == nil then
			return false
		end
	end
	return true
end

-- Post-preparation clipping/list setup and native preflight can replace fields.
-- Keep the cached base immutable and give each pass its own mutable shell.
local function copyBox(base: Box): Box
	local box = table.clone(base)
	box.paint = table.clone(base.paint)
	if base.image then
		box.image = table.clone(base.image)
	end
	return box
end

local function styleDependencies(box: SceneTypes.Box, read: SceneDependencies.Reader): { SceneDependencies.Path }?
	local dependencies: { SceneDependencies.Path } = {}
	local seen: { [Types.Node]: boolean } = {}
	local function include(source: Types.Node): boolean
		if seen[source] then
			return true
		end
		local path = read(source)
		if not path then
			return false
		end
		seen[source] = true
		table.insert(dependencies, path)
		return true
	end
	if not include(box.node) then
		return nil
	end
	for _, run in box.runs or {} do
		if not include(run.source or box.node) then
			return nil
		end
	end
	return dependencies
end

local ScenePreparation = {}
local function rotates(animation: SceneAnimations.Data?, rotation: number): boolean
	if rotation ~= 0 then
		return true
	end
	if not animation then
		return false
	end
	local range = animation.scaleRange
	return animation.rotationNeeded or (animation.scaleNeeded and range ~= nil and range.minimum < 0)
end
local effectDefaults: { [string]: string } = {
	filter = "none",
	["backdrop-filter"] = "none",
	["mask-image"] = "none",
	mask = "none",
	["mix-blend-mode"] = "normal",
	clip = "auto",
}
local canvasText: { Types.ValueToken } = { { kind = "word", value = "canvastext" } }

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function close(a: number, b: number): boolean
	return math.abs(a - b) <= math.max(1, math.abs(a), math.abs(b)) * 1e-6
end

local function sameColor(a: Types.RgbaColor?, b: Types.RgbaColor?): boolean
	return a == b or (a ~= nil and b ~= nil and a.r == b.r and a.g == b.g and a.b == b.b and a.alpha == b.alpha)
end

local function word(style: Types.ComputedStyle, property: string, initial: string): (string?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local tokens = style.properties[property]
	if not tokens then
		return initial, nil
	end
	if #tokens == 1 and tokens[1].kind == "word" then
		return string.lower(tokens[1].value), nil
	end
	return nil, `unsupported-scene-value:{property}`
end

local function zIndex(value: number?): boolean
	return value == nil or finite(value) and value >= -2147483648 and value <= 2147483647 and value % 1 == 0
end

local function resolveOpacity(style: Types.ComputedStyle): (number?, string?)
	if style.unresolved.opacity then
		return nil, style.unresolved.opacity
	end
	local tokens = style.properties.opacity
	if not tokens then
		return 1, nil
	end
	local value, failure = Measurements.resolve(tokens, { percentageDimension = "number" })
	if not value or value.dimension ~= "number" then
		return nil, failure or "invalid-opacity"
	end
	return math.clamp(value.value, 0, 1), nil
end

-- A zero-area basic shape clips the entire element, including descendants.
-- Preserve the layout box and represent that clip as a transparent surface.
local function emptyClipPath(style: Types.ComputedStyle): (boolean, string?)
	local property = "clip-path"
	if style.unresolved[property] then return false, style.unresolved[property] end
	local tokens = style.properties[property]
	if not tokens or (#tokens == 1 and tokens[1].kind == "word" and tokens[1].value:lower() == "none") then
		return false, nil
	end
	if #tokens == 1 and tokens[1].kind == "function" then
		local shape = tokens[1]
		local args = {}
		for _, token in shape.children or {} do
			if token.kind ~= "space" and token.kind ~= "comment" then table.insert(args, token) end
		end
		if #args == 1 and (args[1].kind == "word" or args[1].kind == "percentage" or args[1].kind == "dimension" or args[1].kind == "number") then
			local value = args[1].value:lower()
			if (shape.value:lower() == "inset" and ((args[1].kind == "percentage" and tonumber(value) == 50) or value == "50%"))
				or (shape.value:lower() == "circle" and (tonumber(value) == 0 or value == "0%" or value == "0px")) then
				return true, nil
			end
		end
	end
	return false, "scene-effect-provider-required:clip-path"
end

local function effects(
	style: Types.ComputedStyle,
	paint: NativeBox.Paint,
	metrics: BoxModel.Metrics,
	geometry: BoxModel.Geometry,
	replacedImage: boolean?
): (boolean, string?)
	for property, initial in effectDefaults do
		local value, failure = word(style, property, initial)
		if value ~= initial then
			return false, failure or `scene-effect-provider-required:{property}`
		end
	end
	local visibility, visibilityFailure = word(style, "visibility", "visible")
	if visibility == "hidden" or visibility == "collapse" then
		-- Visibility hides this element's paint, not a descendant that explicitly
		-- restores visibility. A transparent group would hide too much.
		paint.background, paint.border, paint.outline, paint.shadows = nil, nil, nil, nil
		paint.borderEdges = nil
		paint.insetShadows = nil
		paint.outerShadows = nil
		paint.rasterShadows = nil
	elseif visibility ~= "visible" then
		return false, visibilityFailure or "invalid-visibility"
	end
	local x, xFailure = word(style, "overflow-x", "visible")
	local y, yFailure = word(style, "overflow-y", "visible")
	if not x or not y then
		return false, xFailure or yFailure
	end
	if x == "visible" and y == "visible" then
		return true, nil
	end
	-- Roblox provides a rectangular clip for scrollable and clipped overflow.
	local supported = { visible = true, hidden = true, clip = true, auto = true, scroll = true }
	if not supported[x] or not supported[y] then
		return false, "invalid-overflow"
	end
	if x == "clip" and y == "clip" and (style.properties["overflow-clip-margin"] or style.unresolved["overflow-clip-margin"]) then
		if style.unresolved["overflow-clip-margin"] then
			return false, style.unresolved["overflow-clip-margin"]
		end
		local margin = Measurements.resolve(style.properties["overflow-clip-margin"], { strictPercentageTypes = true })
		if
			not margin
			or margin.value ~= 0
			or (margin.percentage or 0) ~= 0
			or (margin.dimension ~= "length" and margin.dimension ~= "number")
		then
			return false, "overflow-clip-margin-provider-required"
		end
	end
	if replacedImage then
		-- This leaf already clips its own image to the content edge. It has
		-- no descendants that could escape the larger padding-edge clip.
		return true, nil
	end
	paint.clip = true
	if (paint.outerShadows and #paint.outerShadows > 0) or paint.rasterShadows then
		-- CSS clips descendants, never this element's own outer shadow. Keep
		-- the existing content/overlay clip separate even with zero borders.
		paint.clipBox = { x = 0, y = 0, width = geometry.width, height = geometry.height }
	end
	for _, width in metrics.border do
		if width ~= 0 then
			paint.clipBox = {
				x = metrics.border.left,
				y = metrics.border.top,
				width = geometry.width - metrics.border.left - metrics.border.right,
				height = geometry.height - metrics.border.top - metrics.border.bottom,
			}
			break
		end
	end
	return true, nil
end

local function prepareLists(result: Prepared): (boolean, string?)
	if next(result.lists) == nil then
		return true, nil
	end
	-- List completeness depends only on direct in-flow render children. Build
	-- this index once rather than scanning the entire scene for each list.
	local children: { [SceneTypes.Key]: { SceneTypes.Key } } = {}
	for key, child in result.boxes do
		local parent = child.source.parent
		if parent ~= nil and not child.source.outOfFlow and result.lists[parent] then
			local siblings = children[parent] or {}
			children[parent] = siblings
			table.insert(siblings, key)
		end
	end
	for key, list in result.lists do
		local parent = result.boxes[key]
		if parent and (parent.kind == "text-input" or parent.kind == "image") then
			return false, "native-replaced-element-cannot-own-scene-list"
		end
		if not parent then
			return false, "missing-native-list-parent"
		end
		if #parent.runs > 0 then
			return false, "mixed-inline-list-provider-required"
		end
		if
			not close(list.plan.width, parent.geometry.contentWidth)
			or not close(list.plan.height, parent.geometry.contentHeight)
		then
			return false, "native-list-content-size-mismatch"
		end
		local selected: { [SceneTypes.Key]: boolean } = {}
		for _, item in list.plan.items do
			local childKey = list.views[item.node]
			local child = if childKey ~= nil then result.boxes[childKey] else nil
			if not child or child.source.parent ~= key or child.source.node ~= item.node or child.source.outOfFlow then
				return false, "native-list-fragment-mismatch"
			end
			if
				child.offsetX ~= 0
				or child.offsetY ~= 0
				or child.rotation ~= 0
				or child.scale ~= 1
				or child.animationModel ~= nil
				or (child.transformTransition ~= nil and child.transformTransition.context)
				or (child.kind ~= "box" and not child.visible)
			then
				local reference = Vector2.new(child.geometry.width, child.geometry.height)
				local offset, failure = NativeDimensions.pair(child.offsetX, child.offsetY, reference)
				if not offset then
					return false, failure
				end
				-- The painted box is now a child of its own used-size carrier.
				-- Fractional size encodings must use that reference, not the list.
				local nativePaint, nativeFailure = NativeBox.prepare(child.geometry, child.paint, reference)
				if not nativePaint then
					return false, nativeFailure
				end
				child.nativePaint = nativePaint
				child.layoutCarrier = true
				child.carrierOffset = offset
				child.reference = reference
			end
			if selected[childKey] then
				return false, "duplicate-native-list-fragment"
			end
			selected[childKey] = true
			if not close(item.width, child.geometry.width) or not close(item.height, child.geometry.height) then
				return false, "native-list-used-size-mismatch"
			end
		end
		for _, childKey in children[key] or {} do
			if not selected[childKey] then
				return false, "unregistered-native-list-fragment"
			end
		end
	end
	return true, nil
end

-- A formatter token certifies immutable source boxes for one geometry/resource
-- epoch. Unmarked/custom scenes keep the ordinary validation path. Retained
-- bases still recheck style dependencies, native eligibility and live opacity;
-- global list, clipping and stacking validation runs on every prepared scene.
function ScenePreparation.prepare(
	plan: SceneTypes.Plan,
	snapshot: SceneTypes.Snapshot,
	fonts: Fonts.Provider,
	systemColors: { [string]: Types.RgbaColor }?,
	retainOpacity: ((SceneTypes.Key, SceneTypes.Box, Transitions.Config?) -> boolean)?,
	paintCache: PaintCache?,
	glyphCache: GlyphCache?,
	boxCache: BoxCache?,
	sourceToken: {}?,
	prepareTransform: ((
		SceneTypes.Key,
		Types.ComputedStyle,
		BoxModel.Geometry,
		Measurements.Context,
		boolean
	) -> (SceneTransforms.Requirement?, string?))?
): (Prepared?, string?, BoxCache?)
	local result: Prepared = { order = {}, boxes = {}, lists = plan.lists or {} }
	local function applyTransform(key: SceneTypes.Key, prepared: Box, style: Types.ComputedStyle): string?
		local requirement: SceneTransforms.Requirement? = nil
		if prepareTransform then
			local value, why =
				prepareTransform(key, style, prepared.geometry, prepared.source.lengths, prepared.animationModel ~= nil)
			if why then
				return why
			end
			requirement = value
		end
		prepared.transformTransition = requirement
		prepared.transformContext = prepared.intrinsicTransformContext or (requirement ~= nil and requirement.context)
		return nil
	end
	local revision = snapshot.layoutRevision
	local nextCache: BoxCache? = if sourceToken and revision ~= nil
		then {
			token = sourceToken,
			revision = revision,
			fonts = fonts,
			systemColors = systemColors,
			entries = {},
			fragments = {},
			keys = {},
		}
		else nil
	local previousCache = if boxCache
			and nextCache
			and boxCache.revision == revision
			and boxCache.fonts == fonts
			and boxCache.systemColors == systemColors
		then boxCache
		else nil
	local nextFragments = if nextCache then nextCache.fragments else nil
	local hasRotation = false
	local controls: { [Types.Node]: boolean }? = nil
	local styles = table.clone(snapshot.styles)
	for node, style in plan.styles or {} do
		if styles[node] then
			return nil, "scene-style-overrides-logical-style", nil
		end
		styles[node] = style
	end
	for node in plan.styles or {} do
		local path: { [Types.Node]: boolean } = {}
		local cursor: Types.Node? = node
		while cursor and not snapshot.styles[cursor] do
			if path[cursor] then
				return nil, "private-scene-style-parent-cycle", nil
			end
			if not styles[cursor] then
				return nil, "unknown-private-scene-style-parent", nil
			end
			path[cursor] = true
			cursor = cursor.parent
		end
	end
	local readDependencies, dependencyPaths =
		SceneDependencies.create(styles, if previousCache then previousCache.dependencies else nil)
	if nextCache then
		nextCache.dependencies = dependencyPaths
	end
	local function glyphStyle(
		style: Types.ComputedStyle,
		inheritedColor: Types.RgbaColor?
	): (GlyphStyle.Style?, string?)
		local cached = if glyphCache then glyphCache[style] else nil
		local glyph: GlyphStyle.Style? = nil
		if
			cached
			and snapshot.layoutRevision ~= nil
			and cached.revision == snapshot.layoutRevision
			and sameColor(cached.inheritedColor, inheritedColor)
		then
			glyph = cached.glyph
		else
			local failure: string?
			glyph, failure =
				GlyphStyle.resolve(style, fonts, { inheritedColor = inheritedColor, systemColors = systemColors })
			if not glyph then
				return nil, failure
			end
			if glyphCache and snapshot.layoutRevision ~= nil then
				glyphCache[style] = {
					revision = snapshot.layoutRevision,
					inheritedColor = if inheritedColor then table.clone(inheritedColor) else nil,
					glyph = glyph,
				}
			end
		end
		return assert(glyph), nil
	end
	local visited: { [SceneTypes.Key]: boolean } = {}
	local active: { [SceneTypes.Key]: boolean } = {}
	local colors: { [Types.Node]: ColorResult } = {}
	local activeColors: { [Types.Node]: boolean } = {}
	local foreground: (Types.Node) -> ColorResult
	foreground = function(node: Types.Node): ColorResult
		local previous = colors[node]
		if previous then
			return previous
		end
		if activeColors[node] then
			return { failure = "scene-color-parent-cycle" }
		end
		activeColors[node] = true
		local style = styles[node]
		if not style then
			activeColors[node] = nil
			return { failure = "unknown-scene-style-source" }
		end
		local parentColor = if node.parent then foreground(node.parent).value else nil
		local value, failure = Colors.resolve(
			style.properties.color or canvasText,
			{ currentColor = parentColor, systemColors = systemColors }
		)
		local resolved: ColorResult = { value = value, failure = style.unresolved.color or failure }
		if style.unresolved.color then
			resolved.value = nil
		end
		colors[node] = resolved
		activeColors[node] = nil
		return resolved
	end
	local visit: (SceneTypes.Key) -> string?
	visit = function(key: SceneTypes.Key): string?
		WorkQueue.checkpoint()
		if active[key] then
			return "scene-parent-cycle"
		end
		if visited[key] then
			return nil
		end
		local box = plan.boxes[key]
		if not box then
			return "missing-scene-parent"
		end
		active[key] = true
		local reference = snapshot.viewport
		if box.parent ~= nil then
			local failure = visit(box.parent)
			if failure then
				return failure
			end
			local parent = result.boxes[box.parent]
			if parent.kind == "text-input" or parent.kind == "image" then
				return "native-replaced-element-cannot-contain-scene-children"
			end
			reference = Vector2.new(parent.geometry.contentWidth, parent.geometry.contentHeight)
			if box.outOfFlow then
				reference = NativeDimensions.overlayReference(reference)
			end
		end
		local style = styles[box.node]
		if not style then
			return "unknown-scene-node"
		end
		if not snapshot.styles[box.owner or box.node] then
			return "unknown-scene-logical-owner"
		end
		local nativeControl = box.node.nativeControl
		if nativeControl ~= nil and nativeControl ~= "auto" and nativeControl ~= "button" then
			return "unknown-native-control"
		end
		if nativeControl == "button" then
			controls = controls or {}
			if assert(controls)[box.node] then
				return "native-control-multiple-fragments-provider-required"
			end
			assert(controls)[box.node] = true
		end
		local parentHidden = box.parent ~= nil and result.boxes[box.parent].hiddenNativeAncestor
		local origin = if nextCache then FormattingFragments.origin(box) else nil
		local cachedBox = if previousCache and previousCache.token == sourceToken
			then previousCache.entries[box]
			else nil
		if not cachedBox and previousCache and origin then
			local retained = previousCache.fragments and previousCache.fragments[origin]
			if
				retained
				and retained.base.animation == nil
				and (not snapshot.animations or snapshot.animations[box.node] == nil)
				and samePlacement(retained.base.source, box)
			then
				cachedBox = retained
			end
		end
		if not cachedBox and previousCache and previousCache.keys then
			local keyed = previousCache.keys[key]
			if
				keyed
				and keyed.base.animation == nil
				and (not snapshot.animations or snapshot.animations[box.node] == nil)
				and sameSource(keyed.base.source, box)
			then
				cachedBox = keyed
			end
		end
		if
			cachedBox
			and (cachedBox.base.transformTransition ~= nil) == (snapshot.transformTransitions ~= nil and snapshot.transformTransitions[box.node] ~= nil)
			and cachedBox.base.reference == reference
			and cachedBox.parentHidden == parentHidden
			and cachedBox.disabled == (box.node.states.disabled == true)
			and cachedBox.nativeControl == nativeControl
		then
			local unchanged = cachedBox.dependencies ~= nil
			if cachedBox.dependencies then
				for _, path in cachedBox.dependencies do
					if readDependencies(path.node) ~= path then
						unchanged = false
						break
					end
				end
			end
			if unchanged then
				for _, run in box.runs or {} do
					local source = run.source or box.node
					local owner = run.owner or (if snapshot.styles[source] then source else box.owner) or source
					if not snapshot.styles[owner] then
						unchanged = false
						break
					end
				end
			end
			if
				unchanged
				and box.kind == "text-input"
				and box.editor
				and box.editor.placeholder
				and box.editor.placeholder ~= ""
			then
				local placeholder = if snapshot.pseudoStyle then snapshot.pseudoStyle(box.node, "placeholder") else nil
				unchanged = placeholder == cachedBox.placeholder
			end
			if unchanged then
				local prepared = copyBox(cachedBox.base)
				prepared.source = box
				local transformFailure = applyTransform(key, prepared, style)
				if transformFailure then
					return transformFailure
				end
				prepared.opacitySurface = prepared.opacity < 1
					or (retainOpacity ~= nil and retainOpacity(key, box, prepared.opacityTransition))
					or (prepared.animation ~= nil and prepared.animation.opacityNeeded)
				hasRotation = hasRotation
					or rotates(prepared.animation, prepared.rotation)
					or (prepared.transformTransition ~= nil and prepared.transformTransition.rotating)
				result.boxes[key] = prepared
				assert(nextCache).entries[box] = cachedBox
				assert(assert(nextCache).keys)[key] = cachedBox
				if origin and nextFragments then
					nextFragments[origin] = cachedBox
				end
				active[key] = nil
				visited[key] = true
				table.insert(result.order, key)
				return nil
			end
		end
		local display, displayFailure = Display.forNode(style, box.node, snapshot.roots[1] == box.node)
		if not display then
			return displayFailure
		end
		if display == "none" or display == "contents" then
			return "nonrendering-node-in-scene"
		end
		if not finite(box.width) or not finite(box.height) or box.width < 0 or box.height < 0 then
			return "invalid-scene-box-size"
		end
		if not zIndex(box.zIndex) or not zIndex(box.paintZIndex) then
			return "invalid-native-stacking-rank"
		end
		local kind: NativeBox.Kind = box.kind or "box"
		if kind ~= "box" and kind ~= "button" and kind ~= "text-input" and kind ~= "image" then
			return "unsupported-native-box-kind"
		end
		if nativeControl == "button" then
			if kind ~= "box" and kind ~= "button" then
				return "native-control-kind-conflict"
			end
			kind = "button"
		end
		local pointerBlocked = false
		if kind == "button" or kind == "text-input" then
			local pointerEvents, pointerFailure = word(style, "pointer-events", "auto")
			if
				pointerEvents ~= "auto"
				and not (pointerEvents == "none" and kind == "button")
			then
				return pointerFailure
					or (
						if kind == "button"
							then "native-button-pointer-events-provider-required"
							else "native-editor-pointer-events-provider-required"
					)
			end
			pointerBlocked = pointerEvents == "none"
		end
		local visibility, visibilityFailure = word(style, "visibility", "visible")
		if not visibility then
			return visibilityFailure
		end
		local visible = visibility == "visible"
		local hiddenNativeAncestor = parentHidden
		if hiddenNativeAncestor and visible then
			return "visible-descendant-of-hidden-native-button-provider-required"
		end
		hiddenNativeAncestor = hiddenNativeAncestor or ((kind == "button" or kind == "text-input") and not visible)
		if style.properties["z-index"] and word(style, "z-index", "auto") ~= "auto" and not box.zIndex then
			return "stacking-rank-provider-required"
		end
		local geometry = BoxModel.fromBorderBox(box.metrics, box.width, box.height)
		if not close(geometry.width, box.width) or not close(geometry.height, box.height) then
			return "insets-exceed-used-scene-box"
		end
		local translation, translationFailure = TranslationTransform.resolve(style, geometry, box.lengths)
		if not translation then
			return translationFailure
		end
		local offsetX, offsetY = (box.offsetX or 0) + translation.x, (box.offsetY or 0) + translation.y
		local rotation, scale = translation.rotation or 0, translation.scale or 1
		local animation = snapshot.animations and snapshot.animations[box.node]
		if animation then
			local computed, why =
				SceneAnimations.prepare(animation, { geometry = geometry, units = box.lengths, style = style })
			if not computed then
				return why
			end
			animation = computed
		end
		local animationModel: AnimationValues.Model? = nil
		if animation and (animation.rotationNeeded or animation.translationNeeded or animation.scaleNeeded) then
			local model, why = AnimationValues.model(style, animation.controlled, geometry, box.lengths)
			if not model then
				return why
			end
			animationModel = model
			if model.scaleDriven then
				local range = assert(animation.scaleRange)
				local samples = { range.minimum, range.maximum }
				for _, entry in animation.effects do
					local track = entry.tracks.scale
					if track then
						for _, value in assert(track.values) do
							assert(type(value) == "number", "animation-scale-number-required")
							table.insert(samples, value)
						end
					end
				end
				for _, value in samples do
					local scaleValue, failure = AnimationValues.nativeScale(model, value)
					if scaleValue == nil then
						return failure
					end
				end
			end
		end
		hasRotation = hasRotation or rotates(animation, rotation)
		local position, positionFailure = NativeDimensions.pair(box.x + offsetX, box.y + offsetY, reference)
		if not position then
			return positionFailure
		end
		local color = foreground(box.node)
		local cached = if paintCache then paintCache[box] else nil
		if not cached and paintCache and previousCache and previousCache.keys then
			local before = previousCache.keys[key]
			local entry = before and before.paint
			if before and before.base.kind == kind and entry and samePaintInputs(before.base, box, geometry) then
				-- The new geometry source needs its own memo shell: later native
				-- reference/effect updates cannot edit the previous commit's entry.
				cached = table.clone(entry)
				paintCache[box] = cached
			end
		end
		local value, oldColor = color.value, if cached then cached.color else nil
		local paint: NativeBox.Paint? = nil
		local paintFailure: string? = nil
		local reusedPaint: PaintEntry? = nil
		local reusedEffects: PreparedEffects? = nil
		if
			cached
			and snapshot.layoutRevision ~= nil
			and cached.revision == snapshot.layoutRevision
			and cached.style == style
			and cached.width == geometry.width
			and cached.height == geometry.height
			and sameColor(value, oldColor)
		then
			local cachedEffects = cached.effects
			if cachedEffects and cachedEffects.replacedImage == (kind == "image") then
				reusedEffects = cachedEffects
			end
			paint = table.clone(if reusedEffects then reusedEffects.paint else cached.paint)
			reusedPaint = cached
		else
			paint, paintFailure = BoxPaint.resolve(style, box.metrics, geometry, {
				lengths = box.lengths,
				currentColor = value,
				systemColors = systemColors,
			})
			if paint and paintCache and snapshot.layoutRevision ~= nil then
				paintCache[box] = {
					revision = snapshot.layoutRevision,
					style = style,
					width = geometry.width,
					height = geometry.height,
					color = if value then table.clone(value) else nil,
					paint = table.clone(paint),
				}
			end
		end
		if not paint then
			return paintFailure
		end
		local opacity: number
		local opacityTransition: Transitions.Config?
		if reusedEffects then
			opacity = reusedEffects.opacity
			opacityTransition = reusedEffects.opacityTransition
		else
			local resolved, opacityFailure = resolveOpacity(style)
			if resolved == nil then
				return opacityFailure
			end
			opacity = resolved
			local transition, transitionFailure = Transitions.resolve(style, "opacity")
			if transitionFailure then
				return transitionFailure
			end
			opacityTransition = transition
		end
		local opacitySurface = opacity < 1 or (retainOpacity ~= nil and retainOpacity(key, box, opacityTransition))
		if animation then
			if
				animation.opacityNeeded
				and opacityTransition
				and opacityTransition.duration + opacityTransition.delay > 0
			then
				return "animation-transition-composition-provider-required:opacity"
			end
			opacitySurface = opacitySurface or animation.opacityNeeded
		end
		if not reusedEffects then
			local supported, effectFailure = effects(style, paint, box.metrics, geometry, kind == "image")
			if not supported then
				return effectFailure
			end
			-- Extend the existing immutable-style/resource-epoch paint memo. Live
			-- opacity retention, source/ancestor checks and list/stacking validation
			-- still run each pass; only successful style-derived work is reused.
			local entry = if paintCache then paintCache[box] else nil
			if entry and snapshot.layoutRevision ~= nil then
				entry.effects = {
					paint = table.clone(paint),
					opacity = opacity,
					opacityTransition = opacityTransition,
					replacedImage = kind == "image",
				}
			end
		end
		local clippedAway, clipFailure = emptyClipPath(style)
		if clipFailure then return clipFailure end
		if clippedAway then opacity, opacitySurface = 0, true end
		if kind == "text-input" and paint.clip and (paint.clipBox or paint.corners) then
			return "native-editor-inner-clip-provider-required"
		end
		if kind == "text-input" and paint.insetShadows and #paint.insetShadows > 0 then
			return "native-editor-inset-shadow-provider-required"
		end
		local nativePaint = if reusedPaint
				and reusedPaint.nativeReference == reference
				and reusedPaint.nativeReplacedImage == (kind == "image")
			then reusedPaint.nativePaint
			else nil
		local nativeFailure: string? = nil
		if not nativePaint then
			nativePaint, nativeFailure = NativeBox.prepare(geometry, paint, reference)
			local entry = if paintCache then paintCache[box] else nil
			if nativePaint and entry and snapshot.layoutRevision ~= nil then
				-- Later clipping setup owns the box's mutable paint shell. Native
				-- preflight belongs to the memo and must not alias that shell.
				local memo = table.clone(nativePaint)
				memo.paint = table.clone(nativePaint.paint)
				nativePaint = memo
				entry.nativePaint = nativePaint
				entry.nativeReference = reference
				entry.nativeReplacedImage = kind == "image"
			end
		end
		if not nativePaint then
			return nativeFailure
		end
		local prepared: Box = {
			source = box,
			kind = kind,
			pointerBlocked = pointerBlocked,
			visible = visible,
			hiddenNativeAncestor = hiddenNativeAncestor,
			geometry = geometry,
			position = position,
			reference = reference,
			offsetX = offsetX,
			offsetY = offsetY,
			transformContext = translation.establishesContext or animationModel ~= nil,
			intrinsicTransformContext = translation.establishesContext or animationModel ~= nil,
			rotation = rotation,
			scale = scale,
			roundedClip = nativePaint.roundedClip,
			layoutCarrier = false,
			paint = paint,
			nativePaint = nativePaint,
			opacity = opacity,
			opacitySurface = opacitySurface,
			opacityTransition = opacityTransition,
			runs = {},
			animation = animation,
			animationModel = animationModel,
		}
		local transformFailure = applyTransform(key, prepared, style)
		if transformFailure then
			return transformFailure
		end
		hasRotation = hasRotation or (prepared.transformTransition ~= nil and prepared.transformTransition.rotating)
		local runKeys: { [SceneTypes.RunKey]: boolean } = {}
		local placeholderStyle: Types.ComputedStyle? = nil
		if kind == "image" then
			if not box.image or box.editor or (box.runs and #box.runs > 0) then
				return "native-image-data-and-no-text-required"
			end
			if box.image.useCurrentColor ~= nil and type(box.image.useCurrentColor) ~= "boolean" then
				return "native-image-color-policy-required"
			end
			if box.image.useCurrentColor and not color.value then
				return color.failure or "native-image-current-color-required"
			end
			local image, imageFailure = NativeImage.prepare(style, box.image.source, {
				width = geometry.contentWidth,
				height = geometry.contentHeight,
				natural = box.image.natural,
				lengths = box.lengths,
			}, {
				geometry = geometry,
				corners = paint.corners,
				perCornerRadius = NativeBox.capabilities().perCornerRadius,
			}, if box.image.useCurrentColor then color.value else nil)
			if not image then
				return imageFailure
			end
			prepared.image = image
		elseif box.image then
			return "image-data-requires-native-image"
		end
		if kind == "text-input" then
			if not box.editor or (box.runs and #box.runs > 0) then
				return "native-editor-data-and-no-glyph-runs-required"
			end
			local inherited = if box.node.parent then foreground(box.node.parent).value else nil
			local glyph, failure = glyphStyle(style, inherited)
			if not glyph then
				return failure
			end
			local placeholder = if snapshot.pseudoStyle
					and box.editor.placeholder
					and box.editor.placeholder ~= ""
				then snapshot.pseudoStyle(box.node, "placeholder")
				else nil
			placeholderStyle = placeholder
			local placeholderGlyph: GlyphStyle.Style? = nil
			if placeholder then
				local pseudoFailure: string?
				placeholderGlyph, pseudoFailure = glyphStyle(placeholder, color.value)
				if not placeholderGlyph then
					return pseudoFailure
				end
			end
			local editor, editorFailure =
				NativeEditor.prepare(style, glyph, box.editor, geometry, placeholder, placeholderGlyph)
			if not editor then
				return editorFailure
			end
			prepared.editor = editor
		elseif box.editor then
			return "editor-data-requires-native-text-input"
		end
		for index, run in box.runs or {} do
			if run.truncate ~= nil and run.truncate ~= "none" and run.truncate ~= "split-word" then
				return "unsupported-native-glyph-truncation"
			end
			local contentFailure = TextContent.validateSingleLine(run.text)
			if contentFailure then
				return contentFailure
			end
			local runKey = run.key or index
			if runKeys[runKey] then
				return "duplicate-scene-glyph-key"
			end
			runKeys[runKey] = true
			if
				not finite(run.width)
				or not finite(run.height)
				or run.width < 0
				or run.height < 0
				or not zIndex(run.zIndex)
			then
				return "invalid-scene-glyph-geometry"
			end
			if run.verticalAlign and run.verticalAlign ~= "top" and run.verticalAlign ~= "center" then
				return "invalid-native-glyph-vertical-alignment"
			end
			local source = run.source or box.node
			local glyphSource = styles[source]
			if not glyphSource then
				return "unknown-scene-glyph-source"
			end
			local owner = run.owner or (if snapshot.styles[source] then source else box.owner) or source
			if not snapshot.styles[owner] then
				return "unknown-scene-glyph-owner"
			end
			local inherited = if source.parent then foreground(source.parent).value else nil
			local glyph, glyphFailure = glyphStyle(glyphSource, inherited)
			if not glyph then
				return glyphFailure
			end
			local glyphVisibility, failure = word(glyphSource, "visibility", "visible")
			if not glyphVisibility then
				return failure
			end
			if glyphVisibility == "hidden" or glyphVisibility == "collapse" then
				-- Visibility changes only this run, never the shared resolved style.
				glyph = table.clone(glyph)
				glyph.color = { value = glyph.color.value, transparency = 1 }
			elseif glyphVisibility ~= "visible" then
				return "invalid-glyph-visibility"
			elseif hiddenNativeAncestor then
				return "visible-descendant-of-hidden-native-button-provider-required"
			end
			local runReference = Vector2.new(geometry.contentWidth, geometry.contentHeight)
			local runPosition, runFailure = NativeDimensions.pair(run.x, run.y, runReference)
			if not runPosition then
				return runFailure
			end
			local size, sizeFailure = NativeDimensions.pair(run.width, run.height, runReference)
			if not size then
				return sizeFailure
			end
			table.insert(prepared.runs, {
				key = runKey,
				source = source,
				owner = owner,
				text = run.text,
				position = runPosition,
				width = run.width,
				height = run.height,
				style = glyph,
				zIndex = run.zIndex or box.zIndex or 1,
				truncate = run.truncate,
				verticalAlign = run.verticalAlign,
			})
		end
		if nextCache then
			local dependencies = styleDependencies(box, readDependencies)
			local entry: BoxEntry = {
				base = prepared,
				paint = if paintCache then paintCache[box] else nil,
				dependencies = dependencies,
				disabled = box.node.states.disabled == true,
				nativeControl = nativeControl,
				parentHidden = parentHidden,
				placeholder = placeholderStyle,
			}
			nextCache.entries[box] = entry
			assert(nextCache.keys)[key] = entry
			if origin and nextFragments then
				nextFragments[origin] = entry
			end
			prepared = copyBox(prepared)
		end
		result.boxes[key] = prepared
		active[key] = nil
		visited[key] = true
		table.insert(result.order, key)
		return nil
	end
	for key in plan.boxes do
		local failure = visit(key)
		if failure then
			return nil, failure, nil
		end
	end
	if hasRotation then
		local scopes: { [SceneTypes.Key]: boolean } = {}
		local descendants: { [SceneTypes.Key]: boolean } = {}
		for index = #result.order, 1, -1 do
			local key = result.order[index]
			local box = result.boxes[key]
			if
				rotates(box.animation, box.rotation)
				or (box.transformTransition ~= nil and box.transformTransition.rotating)
				or descendants[key]
			then
				descendants[key] = true
				if box.source.parent ~= nil then
					descendants[box.source.parent] = true
				end
			end
		end
		for _, key in result.order do
			local box = result.boxes[key]
			local rotated = rotates(box.animation, box.rotation)
				or (box.transformTransition ~= nil and box.transformTransition.rotating)
				or (box.source.parent ~= nil and scopes[box.source.parent] == true)
			scopes[key] = rotated
			-- Native rectangle clipping has rollout/rotated-parent restrictions.
			-- Reuse the existing owned CanvasGroup path only in affected scopes.
			if box.paint.clip and (rotated or descendants[key]) then
				box.paint.groupClip = true
				local native, reason = NativeBox.prepare(box.geometry, box.paint, box.reference)
				if not native then
					return nil, reason, nil
				end
				box.nativePaint, box.roundedClip = native, native.roundedClip
			end
			if box.image and rotated then
				box.image.groupClip = true
			end
		end
	end
	local listsReady, listFailure = prepareLists(result)
	if not listsReady then
		return nil, listFailure, nil
	end
	local stackingAncestors: { [SceneTypes.Key]: boolean } = {}
	for _, key in result.order do
		local box = result.boxes[key]
		local inStackingScope = box.opacitySurface
			or box.transformContext
			or box.roundedClip
			or (box.source.parent ~= nil and stackingAncestors[box.source.parent] == true)
		stackingAncestors[key] = inStackingScope
		if inStackingScope then
			local style = styles[box.source.node]
			local rank, rankFailure = word(style, "z-index", "auto")
			if rank ~= "auto" and box.source.paintZIndex == nil then
				return nil, rankFailure or "native-stacking-context-provider-required", nil
			end
		end
	end
	return result, nil, nextCache
end

return ScenePreparation
