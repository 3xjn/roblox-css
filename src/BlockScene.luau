--!strict

local Types = require(script.Parent.Types)
local TextSegments = require(script.Parent.TextSegments)
local SceneTypes = require(script.Parent.SceneTypes)
local LogicalProperties = require(script.Parent.LogicalProperties)
local Measurements = require(script.Parent.Measurements)
local Typography = require(script.Parent.Typography)
local BoxModel = require(script.Parent.BoxModel)
local BlockSizing = require(script.Parent.BlockSizing)
local BlockFlow = require(script.Parent.BlockFlow)
local Whitespace = require(script.Parent.Whitespace)
local Fonts = require(script.Parent.Fonts)
local TextLine = require(script.Parent.TextLine)
local TextParagraph = require(script.Parent.TextParagraph)
local FlexScene = require(script.Parent.FlexScene)
local GridScene = require(script.Parent.GridScene)
local FlexTypes = require(script.Parent.FlexTypes)
local FlexText = require(script.Parent.FlexText)
local BlockIntrinsic = require(script.Parent.BlockIntrinsic)
local AtomicInline = require(script.Parent.AtomicInline)
local AnonymousFlex = require(script.Parent.AnonymousFlex)
local RelativePosition = require(script.Parent.RelativePosition)
local AspectRatio = require(script.Parent.AspectRatio)
local NativeImage = require(script.Parent.NativeImage)
local AbsolutePosition = require(script.Parent.AbsolutePosition)
local PositionedSizing = require(script.Parent.PositionedSizing)
local FlexStaticPosition = require(script.Parent.FlexStaticPosition)
local ListLayout = require(script.Parent.ListLayout)
local TranslationTransform = require(script.Parent.Transform2D)
local Display = require(script.Parent.Display)
local BoxChildren = require(script.Parent.BoxChildren)
local PositionedPaintOrder = require(script.Parent.PositionedPaintOrder)
local GeneratedContent = require(script.Parent.GeneratedContent)
local BlockMeasurements = require(script.Parent.BlockMeasurements)
local FormattingFragments = require(script.Parent.FormattingFragments)
local FlexLayouts = require(script.Parent.FlexLayouts)
local FlowFragments = require(script.Parent.FlowFragments)
local WorkQueue = require(script.Parent.WorkQueue)
local EditorBaselines = require(script.Parent.EditorBaselines)

export type FlexIntrinsic = FlexScene.Intrinsic
export type FlexIntrinsicRequest = FlexScene.Request
export type FlexIntrinsicProvider = FlexScene.Provider
export type ImageProvider = (Types.Node) -> (NativeImage.Data?, string?)
export type EditorBaselineProvider = EditorBaselines.Provider

export type Options = {
	fonts: Fonts.Provider?,
	textGeometry: TextLine.GeometryProvider?,
	nativeTextLine: boolean?,
	flexIntrinsic: FlexScene.Provider?,
	editorBaselines: EditorBaselines.Provider?,
	imageSource: ImageProvider?,
	-- Paint an otherwise empty CSS box with caller-owned image content. CSS
	-- retains sizing/tag identity; this does not infer replaced-element sizes.
	imageContentSource: ImageProvider?,
	fontMetrics: Typography.MetricsProvider?,
	initialFontSize: number?,
	units: { [string]: number }?,
	-- Exact node inputs for the built-in intrinsic backend. Custom font/geometry
	-- providers omit this contract and retain full subtree invalidation.
	intrinsicInputs: BlockMeasurements.NodeInputs?,
	-- Native consumers only read nested geometry. Ordinary formatter callers
	-- retain fresh mutable records unless they explicitly accept this contract.
	immutableFragments: boolean?,
}
type Layout = { box: SceneTypes.Box, flow: BlockFlow.Result }
type BoxInputs = {
	read metrics: BoxModel.Metrics,
	read lengths: Measurements.Context?,
	read fragments: { FormattingFragments.Entry }?,
}
type AssignedSize = { width: number, height: number, widthDefinite: boolean, heightDefinite: boolean }
type Positioned = FormattingFragments.Positioned
type AnonymousCache = { [Types.Node]: Types.Node }
type PositionedFragment = {
	before: Types.ComputedStyle?,
	after: Types.ComputedStyle?,
	entries: { FormattingFragments.Entry },
}
type GeneratedCache = {
	before: AnonymousCache,
	after: AnonymousCache,
	lines: { [Types.Node]: { [number]: Types.Node } }?,
	textAfter: { [Types.Node]: { [number]: Types.Node } }?,
	measurements: BlockMeasurements.Cache?,
	flow: FlowFragments.State?,
	positionedSizing: PositionedSizing.Cache?,
	positionedFragments: { [{}]: PositionedFragment }?,
	positionedEpoch: number?,
}

local BlockScene = {}

-- A final box must not expose the sizing input held by intrinsic callbacks.
-- Forward its values while keeping the formatter's existing result ownership.
local function copyMetrics(input: BoxModel.Metrics): BoxModel.Metrics
	local result = table.clone(input)
	result.border = table.clone(input.border)
	result.padding = table.clone(input.padding)
	result.margin = {}
	for side, value in input.margin do
		result.margin[side] = table.clone(value)
	end
	return result
end
local function copyLengths(input: Measurements.Context): Measurements.Context
	local result = table.clone(input)
	if input.units then
		result.units = table.clone(input.units)
	end
	if input.mathRange then
		result.mathRange = table.clone(input.mathRange)
	end
	return result
end

local function shiftedBaselines(baselines: SceneTypes.Baselines, offset: number): SceneTypes.Baselines
	local shifted: SceneTypes.Baselines = {
		first = if baselines.first ~= nil then baselines.first + offset else nil,
		last = if baselines.last ~= nil then baselines.last + offset else nil,
	}
	local first, last = shifted.first, shifted.last
	assert(first == nil or (first == first and math.abs(first) < math.huge), "scene-baseline-overflow")
	assert(last == nil or (last == last and math.abs(last) < math.huge), "scene-baseline-overflow")
	return shifted
end
local flowDefaults: { [string]: string } = {
	clear = "none",
	contain = "none",
	["content-visibility"] = "visible",
	["column-count"] = "auto",
	["column-width"] = "auto",
	["column-span"] = "none",
	["align-content"] = "normal",
}
local containingDefaults: { [string]: string } = {
	["will-change"] = "auto",
	["container-type"] = "normal",
	perspective = "none",
}

local function keyword(style: Types.ComputedStyle, property: string, initial: string): (string?, string?)
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
	return nil, `unsupported-block-scene-value:{property}`
end

local function emptyChildren(node: Types.Node, snapshot: SceneTypes.Snapshot): (boolean?, string?)
	local nodeChildren, childrenFailure = BoxChildren.resolve(node, snapshot)
	if not nodeChildren then
		return nil, childrenFailure
	end
	for _, child in nodeChildren do
		local style = snapshot.styles[child]
		if not style then
			return nil, "missing-child-flow-style"
		end
		local display, displayFailure = Display.resolve(style)
		if not display then
			return nil, displayFailure
		end
		if display == "none" then
			continue
		end
		local position, positionFailure = keyword(style, "position", "static")
		if not position then
			return nil, positionFailure
		end
		if position ~= "absolute" and position ~= "fixed" then
			return false, nil
		end
	end
	return true, nil
end

local function lengths(
	style: Types.ComputedStyle,
	snapshot: SceneTypes.Snapshot,
	options: Options,
	rootFontSize: number?,
	rootLineHeight: number?
): Measurements.Context
	local metrics = if options.fontMetrics then options.fontMetrics(style) else nil
	local size = Typography.fontSize(style)
	if not size and not style.properties["font-size"] and not style.unresolved["font-size"] then
		size = options.initialFontSize or snapshot.initialFontSize or 16
	end
	local units = table.clone(options.units or {})
	for _, unit in { "ex", "ch", "cap", "ic" } do
		local ratio = if metrics then metrics[unit] else nil
		units[unit] = if ratio and size then ratio * size else nil
	end
	return {
		fontSize = size,
		lineHeight = Typography.lineHeight(style, metrics),
		rootFontSize = rootFontSize,
		rootLineHeight = rootLineHeight,
		viewportWidth = snapshot.viewport.X,
		viewportHeight = snapshot.viewport.Y,
		units = units,
	}
end

function BlockScene.resolve(
	snapshot: SceneTypes.Snapshot,
	options: Options?,
	anonymousCache: AnonymousCache?,
	generatedCache: GeneratedCache?
): (SceneTypes.Plan?, string?)
	-- Formatting fragments get a private style map. The logical tree, selector
	-- sibling lists and the caller's snapshot remain unchanged.
	snapshot = table.clone(snapshot)
	snapshot.styles = table.clone(snapshot.styles)
	local defaultProjection = snapshot.boxChildren == nil
	local settings: Options = options or {}

	-- The declared built-in readers use the same metrics before and after
	-- blockification. Custom readers can inspect those style overrides.
	local forwardInputs = settings.intrinsicInputs ~= nil
		and settings.editorBaselines == nil
		and not settings.flexIntrinsic
		and not settings.textGeometry
		and not settings.imageSource
		and (not settings.fonts or Fonts.hasDefaultMetrics(settings.fonts))
	local measureAtWidth: ((FlexScene.Request, number) -> (FlexTypes.Size?, string?))? = nil
	local blockMeasurements: { [Types.Node]: { BlockMeasurements.Entry } } = {}
	local intrinsicMeasurements: { [Types.Node]: { BlockMeasurements.Intrinsic } } = {}
	local formattingFragments: { [Types.Node]: { FormattingFragments.Entry } } = {}
	if generatedCache and generatedCache.measurements and not settings.editorBaselines then
		local inputs = if not settings.fonts or Fonts.hasDefaultMetrics(settings.fonts)
			then settings.intrinsicInputs
			else nil
		blockMeasurements, intrinsicMeasurements, formattingFragments =
			BlockMeasurements.prepare(generatedCache.measurements, snapshot, inputs)
	end
	local function rememberIntrinsic(request: FlexScene.Request, kind: "text" | "block", result: FlexScene.Intrinsic)
		local entries = intrinsicMeasurements[request.node]
		if not entries then
			return
		end
		if #entries == 8 then
			table.remove(entries, 1)
		end
		local retained = table.clone(result)
		if kind == "text" and retained.measure then
			retained.measure = BlockMeasurements.retainMeasure(retained.measure)
		end
		table.insert(entries, {
			width = request.width,
			height = request.height,
			flow = request.flow,
			kind = kind,
			result = retained,
		})
	end
	local function intrinsic(request: FlexScene.Request): (FlexScene.Intrinsic?, string?)
		if settings.flexIntrinsic then
			local result, failure = settings.flexIntrinsic(request)
			if result or failure then
				return result, failure
			end
		end
		local cached: BlockMeasurements.Intrinsic? = nil
		for _, entry in intrinsicMeasurements[request.node] or {} do
			if entry.width == request.width and entry.height == request.height and entry.flow == request.flow then
				cached = entry
				break
			end
		end
		if cached and cached.kind == "text" then
			return table.clone(cached.result), nil
		end
		local textOptions: FlexText.Options = {
			fonts = settings.fonts,
			geometry = settings.textGeometry,
			nativeTextLine = settings.nativeTextLine,
			fontMetrics = settings.fontMetrics,
		}
		local text: FlexScene.Intrinsic? = nil
		local failure: string? = nil
		if not cached then
			text, failure = FlexText.resolve(request, textOptions)
		end
		if text or failure then
			if text and not failure then
				rememberIntrinsic(request, "text", text)
			end
			return text, failure
		end
		-- Width contributions are independent of the requesting flex axis.
		-- A column derives block-axis content at its final cross width through
		-- the same formatter callback, rather than treating a width as a base.
		local measured: FlexScene.Intrinsic? = if cached then table.clone(cached.result) else nil
		local blockFailure: string? = nil
		local inlineSizeRequired = request.inlineSizeRequired ~= false
		if not cached and inlineSizeRequired then
			local widthRequest = table.clone(request)
			widthRequest.flow = "row"
			measured, blockFailure = BlockIntrinsic.resolve(widthRequest, {
				flexIntrinsic = settings.flexIntrinsic,
				fonts = textOptions.fonts,
				geometry = textOptions.geometry,
				nativeTextLine = textOptions.nativeTextLine,
				fontMetrics = textOptions.fontMetrics,
				getLengths = function(style)
					return lengths(
						style,
						snapshot,
						settings,
						request.lengths.rootFontSize,
						request.lengths.rootLineHeight
					)
				end,
			})
		end
		if measured == nil and blockFailure == nil then
			-- Used-width height measurement does not require intrinsic inline
			-- contributions (for example a wrapper containing an editor).
			-- Both axes can use this callback. FlexSizing still requires actual
			-- width contributions when its basis or automatic minimum needs them.
			local contribution: FlexScene.Intrinsic = {}
			measured = contribution
		end
		if measured and not blockFailure and not cached and inlineSizeRequired then
			rememberIntrinsic(request, "block", measured)
		end
		if measured then
			if request.flow == "column" or request.flow == "column-reverse" then
				measured.flexBase = nil
			end
			measured.measure = function(constraints: FlexTypes.Constraints): (FlexTypes.Size?, string?)
				if
					constraints.widthMode ~= "exactly"
					or constraints.width == nil
					or constraints.heightMode ~= "undefined"
				then
					return nil, "block-intrinsic-measurement-constraints-required"
				end
				return assert(measureAtWidth, "block measurement formatter is not initialized")(
					request,
					constraints.width
				)
			end
		end
		return measured, blockFailure
	end
	local plan: SceneTypes.Plan = { boxes = {} }
	local lists: { [SceneTypes.Key]: SceneTypes.List } = {}
	plan.lists = lists
	local privateStyles: { [Types.Node]: Types.ComputedStyle } = {}
	plan.styles = privateStyles
	local anonymousNodes: AnonymousCache = anonymousCache or {}
	local generatedNodes: GeneratedCache = generatedCache or { before = {}, after = {} }
	if not generatedNodes.lines then
		generatedNodes.lines = setmetatable({}, { __mode = "k" })
	end
	local lineNodes = assert(generatedNodes.lines)
	local generatedOwners: { [Types.Node]: Types.Node } = {}
	local function pseudoFragment(
		origin: Types.Node,
		name: string,
		restoringFlow: FlowFragments.State?
	): (Types.Node?, string?)
		if not snapshot.pseudoStyle or generatedOwners[origin] then
			return nil, nil
		end
		-- Native replaced/editable interiors do not generate these CSS boxes.
		if origin.tag == "img" or origin.tag == "input" or origin.tag == "textarea" then
			return nil, nil
		end
		local pseudo = snapshot.pseudoStyle(origin, name)
		if not pseudo then
			return nil, nil
		end
		local kind, failure = GeneratedContent.resolve(pseudo)
		if not kind then
			return nil, failure
		elseif kind == "none" then
			return nil, nil
		end
		local position, positionFailure = keyword(pseudo, "position", "static")
		if position ~= "absolute" and position ~= "fixed" then
			return nil, positionFailure or `generated-in-flow-box-provider-required:{name}`
		end
		local cache = if name == "before" then generatedNodes.before else generatedNodes.after
		local fragment = cache[origin]
		if not fragment then
			local created: Types.Node = {
				tag = "#" .. name,
				className = "",
				classes = {},
				attributes = {},
				states = {},
				text = "",
				parent = origin,
				children = {},
			}
			fragment = created
			cache[origin] = fragment
		end
		-- Content has been consumed by this formatter. The public pseudo style
		-- retains its original empty string and originating-element inheritance.
		-- Flow restoration already retains this exact source's normalized style.
		-- Borrow it before allocating a duplicate that would be discarded later.
		local retained = restoringFlow and restoringFlow.pseudos[fragment]
		local formatting = if retained and retained.source == pseudo then retained.style else nil
		if not formatting then
			formatting = table.clone(pseudo)
			formatting.properties = table.clone(pseudo.properties)
			formatting.properties.content = { { kind = "word", value = "normal" } }
		end
		snapshot.styles[fragment] = formatting
		if snapshot.transformTransition and snapshot.transformTransitions then
			local requirement, why = snapshot.transformTransition(fragment, assert(formatting))
			if why then
				return nil, why
			end
			snapshot.transformTransitions[fragment] = requirement
		end
		privateStyles[fragment] = formatting
		generatedOwners[fragment] = origin
		return fragment, nil
	end
	local function childPseudoFragment(origin: Types.Node, name: string): (Types.Node?, string?)
		return pseudoFragment(origin, name)
	end
	local projectedChildren: { [Types.Node]: { Types.Node } } = {}
	snapshot.boxChildren = function(node: Types.Node): ({ Types.Node }?, string?)
		local previous = projectedChildren[node]
		if previous then
			return previous, nil
		end
		local result, failure = BoxChildren.project(node, snapshot, childPseudoFragment)
		if result then
			projectedChildren[node] = result
		end
		return result, failure
	end
	if #snapshot.roots == 0 then
		return plan, nil
	end
	if #snapshot.roots ~= 1 then
		return nil, "block-scene-single-document-root-required"
	end
	local root = snapshot.roots[1]
	local rootStyle = snapshot.styles[root]
	if not rootStyle then
		return nil, "missing-block-scene-root-style"
	end
	local rootLengths = lengths(rootStyle, snapshot, settings, nil, nil)
	local rootDirection, rootFailure = keyword(rootStyle, "direction", "ltr")
	if not rootDirection then
		return nil, rootFailure
	end
	local rank = 0
	local positioned: { Positioned } = {}
	local nextPositionedFragments: { [{}]: PositionedFragment } = {}
	local previousPositionedFragments = if generatedCache
			and generatedCache.positionedEpoch == snapshot.layoutRevision
		then generatedCache.positionedFragments
		else nil
	local visit: (
		Types.Node,
		Types.Node?,
		number,
		number?,
		string,
		AssignedSize?,
		boolean?,
		number?,
		BoxInputs?,
		boolean?
	) -> (Layout?, string?)
	visit = function(
		node: Types.Node,
		parent: Types.Node?,
		width: number,
		height: number?,
		direction: string,
		assigned: AssignedSize?,
		absoluteAssignment: boolean?,
		measuredWidth: number?,
		preparedInputs: BoxInputs?,
		baselineRequired: boolean?
	): (Layout?, string?)
		WorkQueue.checkpoint()
		local source = snapshot.styles[node]
		if not source then
			return nil, "missing-block-scene-style"
		end
		local fragmentEntries = if preparedInputs and preparedInputs.fragments
			then preparedInputs.fragments
			else formattingFragments[node]
		local constraints: FormattingFragments.Constraints? = if fragmentEntries
			then {
				parent = parent,
				width = width,
				height = height,
				direction = direction,
				assignedWidth = if assigned then assigned.width else nil,
				assignedHeight = if assigned then assigned.height else nil,
				widthDefinite = if assigned then assigned.widthDefinite else nil,
				heightDefinite = if assigned then assigned.heightDefinite else nil,
				absoluteAssignment = absoluteAssignment,
				measuredWidth = measuredWidth,
			}
			else nil
		local firstRank, firstPositioned = rank, #positioned
		if fragmentEntries and constraints then
			local cached = FormattingFragments.find(fragmentEntries, constraints)
			if cached then
				local layout, nextRank, failure = FormattingFragments.restore(
					cached,
					plan,
					rank,
					settings.imageContentSource,
					snapshot,
					generatedOwners,
					positioned,
					settings.immutableFragments
				)
				if failure then
					return nil, failure
				end
				if layout then
					rank = assert(nextRank)
					return layout, nil
				end
				local index = table.find(fragmentEntries, cached)
				if index then
					table.remove(fragmentEntries, index)
				end
			end
		end
		local baselineStyle = source
		local function finish(layout: Layout): (Layout?, string?)
			if baselineRequired and layout.box.editor and settings.editorBaselines then
				local baselines, failure = EditorBaselines.resolve(layout.box, baselineStyle, settings.editorBaselines)
				if failure then
					return nil, failure
				end
				layout.box.baselines = baselines
			end
			if fragmentEntries and constraints then
				local keys: { SceneTypes.Key } = {}
				local privateKeys: { Types.Node } = {}
				local function collect(logical: Types.Node)
					if plan.boxes[logical] then
						table.insert(keys, logical)
					end
					local anonymous = anonymousNodes[logical]
					if anonymous and plan.boxes[anonymous] then
						table.insert(keys, anonymous)
					end
					local afterCache = generatedNodes.textAfter
					for _, fragment in if afterCache then afterCache[logical] or {} else {} do
						if plan.boxes[fragment] then
							table.insert(keys, fragment)
						end
					end
					for _, line in lineNodes[logical] or {} do
						if plan.boxes[line] then
							table.insert(keys, line)
						end
					end
					for _, cache in { generatedNodes.before, generatedNodes.after } do
						local fragment = cache[logical]
						if fragment and generatedOwners[fragment] then
							table.insert(privateKeys, fragment)
						end
					end
					for _, child in logical.children do
						collect(child)
					end
				end
				collect(node)
				local pending: { Positioned } = {}
				for i = firstPositioned + 1, #positioned do
					table.insert(pending, positioned[i])
				end
				FormattingFragments.capture(
					fragmentEntries,
					constraints,
					layout,
					keys,
					plan,
					firstRank,
					rank,
					pending,
					generatedOwners,
					privateKeys,
					settings.immutableFragments
				)
			end
			return layout, nil
		end
		local style, mappingFailure = LogicalProperties.view(source)
		if not style then
			return nil, mappingFailure
		end
		local display, displayFailure = Display.forNode(style, node, snapshot.roots[1] == node)
		if not display then
			return nil, displayFailure
		end
		if display == "none" then
			return nil, nil
		end
		local nodeChildren, projectionFailure = BoxChildren.resolve(node, snapshot)
		if not nodeChildren then
			return nil, projectionFailure
		end
		if generatedOwners[node] then
			privateStyles[node] = source
		end
		local position, positionFailure = keyword(style, "position", "static")
		if not position then
			return nil, positionFailure
		end
		if (position == "absolute" or position == "fixed") and not absoluteAssignment then
			table.insert(positioned, { node = node, parent = parent })
			return nil, nil
		end
		if absoluteAssignment then
			-- Assigned absolute geometry supplies the outer sizing/placement.
			-- Interior formatting still uses the same block/flex implementation.
			style = table.clone(style)
			style.properties = table.clone(style.properties)
			style.properties.position = { { kind = "word", value = "static" } }
		end
		local before, beforeFailure = pseudoFragment(node, "before")
		if beforeFailure then
			return nil, beforeFailure
		elseif before then
			table.insert(positioned, { node = before, parent = node })
		end
		local after, afterFailure = pseudoFragment(node, "after")
		if afterFailure then
			return nil, afterFailure
		end
		local inputType = if node.tag == "input" then string.lower(node.attributes.type or "text") else ""
		local editable = node.tag == "textarea" or (node.tag == "input" and (
			inputType == "text" or inputType == "search" or inputType == "email"
			or inputType == "tel" or inputType == "url" or inputType == "number"
		))
		local image = node.tag == "img"
		local imageContent: NativeImage.Data? = nil
		if settings.imageContentSource and not image then
			local failure: string?
			imageContent, failure = settings.imageContentSource(node)
			if failure then
				return nil, failure
			end
			if imageContent and (editable or node.tag == "button" or #node.children > 0 or node.text ~= "") then
				return nil, "image-content-requires-passive-leaf-box"
			end
		end
		if image and (#node.children > 0 or node.text ~= "") then
			return nil, "native-image-requires-leaf-without-glyph-text"
		end
		if editable then
			if #node.children > 0 or node.text ~= "" then
				return nil, "native-editor-requires-leaf-without-glyph-text"
			end
		end
		-- Roots and assigned flex/absolute boxes blockify their outer role.
		-- Keep inner flow-root/flex semantics and leave logical styles untouched.
		local normalized, normalizationFailure =
			Display.resolve(style, not parent or assigned ~= nil or measuredWidth ~= nil)
		if not normalized then
			return nil, normalizationFailure
		end
		display = if normalized == "contents" and snapshot.roots[1] == node then "block" else Display.format(normalized)
		style = table.clone(style)
		style.properties = table.clone(style.properties)
		style.properties.display = { { kind = "word", value = display } }
		if measuredWidth ~= nil then
			-- The flex frontend applies the subject's preferred/min/max block
			-- constraints after measuring content. Keep them out of the raw
			-- height suggestion; descendants retain their ordinary styles.
			style.properties.height = { { kind = "word", value = "auto" } }
			style.properties["min-height"] = { { kind = "number", value = "0" } }
			style.properties["max-height"] = { { kind = "word", value = "none" } }
		end
		-- The native editor owns its interior, including after inline-flex
		-- blockification. It cannot become a CSS child container.
		if (editable or image or imageContent ~= nil) and (display == "flex" or display == "grid") then
			display = "block"
			style.properties.display = { { kind = "word", value = display } }
		end
		if display ~= "block" and display ~= "flow-root" and display ~= "flex" and display ~= "grid" then
			return nil, `formatting-provider-required:{display}`
		end
		baselineStyle = style
		local segmentFailure = TextSegments.validate(node.textAfter, #node.children)
		if segmentFailure then
			return nil, segmentFailure
		end
		if TextSegments.has(node.textAfter) and display ~= "flex" then
			return nil, `ordered-text-formatting-provider-required:{display}`
		end
		local textAtoms: { Whitespace.Atom }? = nil
		if node.text ~= "" and not (display == "flex" and node.text:match("^[ \t\n\r]*$")) then
			local policy, policyFailure = Whitespace.resolve(style)
			if not policy then
				return nil, policyFailure
			end
			local atoms, textFailure = Whitespace.process({ { source = node, text = node.text, policy = policy } })
			if not atoms then
				return nil, textFailure
			end
			for _, atom in atoms do
				if not atom.discarded and (atom.kind ~= "space" or not atom.collapsible) then
					textAtoms = atoms
					break
				end
			end
			-- Whitespace-only anonymous block content does not generate line boxes.
		end
		-- These properties change layout or paint order. They cannot be silently
		-- ignored while treating an element as ordinary static block content.
		for property, initial in flowDefaults do
			if (display == "flex" or display == "grid" or editable) and property == "align-content" then
				continue
			end
			local value, failure = keyword(style, property, initial)
			if value ~= initial then
				return nil, failure or `block-scene-provider-required:{property}`
			end
		end
		local childDirection, directionFailure = keyword(style, "direction", "ltr")
		if not childDirection then
			return nil, directionFailure
		end

		local supplied = if forwardInputs then preparedInputs else nil
		-- Normalization above changes display, position and preferred block
		-- sizes, which are not box-metric or built-in font-unit inputs.
		local units = if supplied and supplied.lengths
			then copyLengths(supplied.lengths)
			else lengths(style, snapshot, settings, rootLengths.fontSize, rootLengths.lineHeight)
		local offset, offsetFailure = RelativePosition.resolve(style, {
			width = width,
			height = height,
			direction = direction,
			lengths = units,
		})
		if not offset then
			return nil, offsetFailure
		end

		local metrics: BoxModel.Metrics? = if supplied then copyMetrics(supplied.metrics) else nil
		local metricFailure: string? = nil
		if not metrics then
			metrics, metricFailure = BoxModel.resolveMetrics(style, { lengths = units, containingInlineSize = width })
		end
		if not metrics then
			return nil, metricFailure
		end
		if image then
			local data: NativeImage.Data? = nil
			local resourceFailure: string? = nil
			if settings.imageSource then
				data, resourceFailure = settings.imageSource(node)
			end
			if resourceFailure then
				return nil, resourceFailure
			end
			local src: string? = node.attributes.src
			if not data and src then
				local fallback: NativeImage.Data = { source = src }
				data = fallback
			end
			if not data then
				return nil, "native-image-resource-provider-required"
			end
			local inline: BlockSizing.InlineSize? = nil
			local block: BlockSizing.BlockSize? = nil
			local sizingFailure: string? = nil
			if assigned then
				if assigned.width < metrics.horizontalInset or assigned.height < metrics.verticalInset then
					return nil, "flex-image-insets-exceed-used-size"
				end
				inline = {
					width = assigned.width,
					contentWidth = assigned.width - metrics.horizontalInset,
					marginLeft = 0,
					marginRight = 0,
				}
				local used: BlockSizing.BlockSize = {
					height = assigned.height,
					contentHeight = assigned.height - metrics.verticalInset,
					marginTop = 0,
					marginBottom = 0,
					automatic = false,
					minimumContentHeight = 0,
				}
				block = used
			else
				inline, block, sizingFailure = BlockSizing.resolveReplaced(style, metrics, {
					width = width,
					height = height,
					direction = direction,
					lengths = units,
					natural = data.natural,
				})
			end
			if not inline then
				return nil, sizingFailure
			end
			if not block then
				return nil, sizingFailure
			end
			rank += 1
			local box: SceneTypes.Box = {
				node = node,
				kind = "image",
				image = data,
				outOfFlow = absoluteAssignment,
				parent = parent,
				x = inline.marginLeft,
				y = if parent then 0 else block.marginTop,
				offsetX = offset.x,
				offsetY = offset.y,
				width = inline.width,
				height = block.height,
				metrics = metrics,
				lengths = units,
				zIndex = rank,
			}
			plan.boxes[node] = box
			local flow = BlockFlow.resolve({}, {
				marginTop = block.marginTop,
				marginBottom = block.marginBottom,
				collapseTop = false,
				collapseBottom = false,
				canCollapseThrough = false,
				minimumContentHeight = 0,
			})
			return finish({ box = box, flow = flow })
		end
		local ratio, ratioFailure = AspectRatio.resolve(style, metrics)
		if ratioFailure then
			return nil, ratioFailure
		end
		if editable and ratio then
			return nil, "native-editor-ratio-intrinsics-provider-required"
		end
		local generated = keyword(style, "content", "normal")
		local noFlowChildren, childrenFailure = emptyChildren(node, snapshot)
		if noFlowChildren == nil then
			return nil, childrenFailure
		end
		local emptyContent = node.text == ""
			and not TextSegments.has(node.textAfter)
			and noFlowChildren
			and not editable
			and (generated == "normal" or generated == "none")
		local inline: BlockSizing.InlineSize?
		local inlineFailure: string?
		if measuredWidth ~= nil then
			if measuredWidth < metrics.horizontalInset then
				return nil, "measured-block-insets-exceed-used-width"
			end
			inline = {
				width = measuredWidth,
				contentWidth = measuredWidth - metrics.horizontalInset,
				marginLeft = 0,
				marginRight = 0,
			}
		elseif assigned then
			-- Intrinsic contributions were computed without cyclic percentages.
			-- This is the final used-size pass: descendants resolve inline
			-- percentages against this size without re-sizing their containing
			-- block (CSS Sizing 3, section 5.2.1). Block-axis definiteness remains
			-- independent and still gates percentage heights below.
			if assigned.width < metrics.horizontalInset or assigned.height < metrics.verticalInset then
				return nil, "flex-item-insets-exceed-used-size"
			end
			inline = {
				width = assigned.width,
				contentWidth = assigned.width - metrics.horizontalInset,
				marginLeft = 0,
				marginRight = 0,
			}
		else
			inline, inlineFailure = BlockSizing.resolveInline(style, metrics, {
				width = width,
				height = height,
				direction = direction,
				lengths = units,
				minContentWidth = if emptyContent then 0 else nil,
			})
		end
		if not inline then
			return nil, inlineFailure
		end
		local preliminary: BlockSizing.BlockSize?
		local heightFailure: string?
		-- The single-line editor backend can use an explicit computed line box
		-- as its preferred content height. It has no UA/font-normal or multiline
		-- intrinsic-height fallback, and its native text baseline stays unknown.
		local editorContentHeight = if node.tag == "input" and not style.unresolved["line-height"]
			then Typography.lineHeight(style)
			else nil
		if assigned then
			local used: BlockSizing.BlockSize = {
				height = assigned.height,
				contentHeight = assigned.height - metrics.verticalInset,
				marginTop = 0,
				marginBottom = 0,
				automatic = false,
				minimumContentHeight = 0,
				preferredContentHeight = assigned.height - metrics.verticalInset,
			}
			preliminary = used
		else
			preliminary, heightFailure = BlockSizing.resolveBlock(style, metrics, {
				width = inline.contentWidth,
				height = height,
				autoContentHeight = editorContentHeight or 0,
				lengths = units,
				minContentHeight = if emptyContent then 0 else editorContentHeight,
			})
		end
		if not preliminary then
			return nil, heightFailure
		end
		if editable and preliminary.automatic and editorContentHeight == nil then
			return nil, "native-editor-intrinsic-height-provider-required"
		end
		local overflowX, xFailure = keyword(style, "overflow-x", "visible")
		local overflowY, yFailure = keyword(style, "overflow-y", "visible")
		if not overflowX or not overflowY then
			return nil, xFailure or yFailure
		end
		local establishesFormattingContext = not parent
			or editable
			or assigned ~= nil
			or measuredWidth ~= nil
			or display == "flex"
			or display == "grid"
			or display == "flow-root"
			or (overflowX ~= "visible" and overflowX ~= "clip")
			or (overflowY ~= "visible" and overflowY ~= "clip")
		rank += 1
		local box: SceneTypes.Box = {
			node = node,
			owner = generatedOwners[node],
			kind = if imageContent
				then "image"
				elseif editable then "text-input"
				elseif node.tag == "button" then "button"
				else "box",
			image = imageContent,
			outOfFlow = absoluteAssignment,
			editor = if editable
				then {
					value = node.attributes.value,
					defaultValue = node.attributes["default-value"],
					placeholder = node.attributes.placeholder,
					multiline = node.tag == "textarea",
				}
				else nil,
			parent = parent,
			x = inline.marginLeft,
			y = 0,
			offsetX = offset.x,
			offsetY = offset.y,
			width = inline.width,
			height = 0,
			metrics = metrics,
			lengths = units,
			-- Native editing owns a text baseline, but does not expose its
			-- calibration. Preserve unknown instead of declaring an empty box.
			baselines = if editable then {} else nil,
			zIndex = rank,
		}
		local childHeight = if assigned and not assigned.heightDefinite
			then nil
			elseif preliminary.automatic then nil
			else preliminary.contentHeight
		if display == "grid" then
			local gridBlock: BlockSizing.BlockSize = preliminary
			local gridMetrics, gridWidth = metrics, inline.contentWidth
			local grid, gridFailure = GridScene.resolve(
				node,
				style,
				snapshot,
				{
					width = inline.contentWidth,
					height = childHeight,
					lengths = units,
				},
				function(childStyle)
					return lengths(childStyle, snapshot, settings, rootLengths.fontSize, rootLengths.lineHeight)
				end,
				intrinsic,
				function(naturalHeight: number): (number?, string?)
					if not assigned then
						local final, failure = BlockSizing.resolveBlock(style, gridMetrics, {
							width = gridWidth,
							minContentHeight = if emptyContent then 0 else nil,
							height = height,
							autoContentHeight = naturalHeight,
							lengths = units,
						})
						if not final then
							return nil, failure
						end
						gridBlock = final
					end
					return gridBlock.contentHeight, nil
				end
			)
			if not grid then
				return nil, gridFailure
			end
			for _, used in grid.used do
				local child, failure = visit(used.item.node, node, used.areaWidth, used.areaHeight, childDirection, {
					width = used.width,
					height = used.height,
					widthDefinite = used.widthDefinite,
					heightDefinite = used.heightDefinite,
				}, nil, nil, { metrics = used.item.metrics, lengths = used.item.lengths }, false)
				if not child then
					return nil, failure or "missing-grid-scene-child"
				end
				child.box.x, child.box.y = used.x, used.y
			end
			box.height, box.baselines = gridBlock.height, {}
			if not parent then
				box.y = gridBlock.marginTop
			end
			plan.boxes[node] = box
			if after then
				table.insert(positioned, { node = after, parent = node })
			end
			local flow = BlockFlow.resolve({}, {
				marginTop = gridBlock.marginTop,
				marginBottom = gridBlock.marginBottom,
				collapseTop = false,
				collapseBottom = false,
				canCollapseThrough = false,
				minimumContentHeight = 0,
			})
			return finish({ box = box, flow = flow })
		end
		if display == "flex" then
			for _, child in nodeChildren do
				local childStyle = snapshot.styles[child]
				if childStyle and (keyword(childStyle, "position", "static") == "absolute" or keyword(childStyle, "position", "static") == "fixed") then
					local _, failure = visit(child, node, inline.contentWidth, childHeight, childDirection, nil, false)
					if failure then
						return nil, failure
					end
				end
			end
			local anonymous: AnonymousFlex.Prepared? = nil
			local textOptions: AnonymousFlex.Options = {
				fonts = settings.fonts,
				geometry = settings.textGeometry,
				fontMetrics = settings.fontMetrics,
				nativeTextLine = settings.nativeTextLine,
			}
			if textAtoms then
				local fragment = anonymousNodes[node]
				if not fragment then
					local created: Types.Node = {
						tag = "#text",
						className = "",
						classes = {},
						attributes = {},
						states = {},
						text = node.text,
						parent = node,
						children = {},
					}
					fragment = created
					anonymousNodes[node] = fragment
				end
				fragment.text = node.text
				local flow = keyword(style, "flex-direction", "row")
				local failure: string?
				anonymous, failure = AnonymousFlex.prepare(node, fragment, snapshot, textOptions, function(childStyle)
					return lengths(childStyle, snapshot, settings, rootLengths.fontSize, rootLengths.lineHeight)
				end, inline.contentWidth, flow == "row" or flow == "row-reverse")
				if not anonymous then
					return nil, failure
				end
				privateStyles[fragment] = anonymous.style
			end
			local afterAnonymous: { [Types.Node]: AnonymousFlex.Prepared }? = nil
			local suppliedAnonymous: { [Types.Node]: FlexTypes.Item }? = nil
			local orderedChildren: { Types.Node }? = nil
			if TextSegments.has(node.textAfter) then
				afterAnonymous, suppliedAnonymous = {}, {}
				if not generatedNodes.textAfter then
					generatedNodes.textAfter = setmetatable({}, { __mode = "k" })
				end
				local caches = assert(generatedNodes.textAfter)
				local fragments = caches[node]
				if not fragments then
					fragments = setmetatable({}, { __mode = "v" })
					caches[node] = fragments
				end
				local flow = keyword(style, "flex-direction", "row")
				local textWidth = inline.contentWidth
				local projected, failure = BoxChildren.withText(node, nodeChildren, function(index, text)
					if index == 0 or text:match("^[ \t\n\r]*$") then
						return nil, nil
					end
					local fragment = assert(fragments)[index]
					if not fragment then
						local created: Types.Node = {
							tag = "#text",
							className = "",
							classes = {},
							attributes = {},
							states = {},
							text = text,
							parent = node,
							children = {},
						}
						fragment = created
						assert(fragments)[index] = fragment
					end
					fragment.text = text
					local prepared, reason = AnonymousFlex.prepare(
						node,
						fragment,
						snapshot,
						textOptions,
						function(childStyle)
							return lengths(childStyle, snapshot, settings, rootLengths.fontSize, rootLengths.lineHeight)
						end,
						textWidth,
						flow == "row" or flow == "row-reverse",
						text
					)
					if not prepared then
						return nil, reason or "anonymous-text-preparation-failed"
					end
					privateStyles[fragment] = prepared.style
					assert(afterAnonymous)[fragment] = prepared
					assert(suppliedAnonymous)[fragment] = prepared.item
					return fragment, nil
				end)
				if not projected then
					return nil, failure
				end
				orderedChildren = projected
			end
			local flexContext: FlexTypes.Context = {
				relativePositioning = true,
				width = inline.contentWidth,
				height = preliminary.contentHeight,
				heightDefinite = childHeight ~= nil,
				autoHeight = not assigned and preliminary.automatic,
				minHeight = preliminary.minimumContentHeight,
				maxHeight = preliminary.maximumContentHeight,
				lengths = units,
			}
			local entries = if forwardInputs
					and defaultProjection
					and generatedCache
					and generatedCache.measurements
				then BlockMeasurements.flex(generatedCache.measurements, node)
				else nil
			local leading = if anonymous then anonymous.item.node else nil
			local flex = if entries then FlexLayouts.find(entries, flexContext, leading) else nil
			local flexFailure: string?
			if flex then
				local valid, reason = FlexScene.validateChildren(node, snapshot, suppliedAnonymous, orderedChildren)
				if not valid then
					return nil, reason
				end
			else
				flex, flexFailure = FlexScene.resolve(node, style, snapshot, flexContext, function(childStyle)
					return lengths(childStyle, snapshot, settings, rootLengths.fontSize, rootLengths.lineHeight)
				end, intrinsic, if anonymous then anonymous.item else nil, suppliedAnonymous, orderedChildren)
				if flex and entries then
					FlexLayouts.capture(entries, flexContext, leading, flex)
				end
			end
			if not flex then
				return nil, flexFailure
			end
			local flexInputs: { [Types.Node]: FlexTypes.Item } = flex.inputs or {}
			local flexBlock: BlockSizing.BlockSize = preliminary
			if not assigned then
				local final, failure = BlockSizing.resolveBlock(style, metrics, {
					width = inline.contentWidth,
					minContentHeight = if emptyContent then 0 else nil,
					height = height,
					autoContentHeight = flex.height,
					lengths = units,
				})
				if not final then
					return nil, failure
				end
				flexBlock = final
			end
			local contentWidth = inline.contentWidth
			local baselineItemsRequired = baselineRequired and #flex.used == 1 and not flex.lines
			local function renderItems(
				sizes: { FlexTypes.UsedItem },
				parentKey: Types.Node,
				currentAnonymous: AnonymousFlex.Prepared?
			): ({ [Types.Node]: SceneTypes.Key }?, string?)
				local views: { [Types.Node]: SceneTypes.Key } = {}
				for _, size in sizes do
					local textItem = if currentAnonymous and size.node == currentAnonymous.item.node
						then currentAnonymous
						else afterAnonymous and assert(afterAnonymous)[size.node]
					if textItem then
						rank += 1
						local fragment, failure =
							AnonymousFlex.layout(textItem, node, size, snapshot, textOptions, parentKey, rank)
						if not fragment then
							return nil, failure
						end
						plan.boxes[size.node] = fragment
					else
						local child, failure = visit(
							size.node,
							parentKey,
							contentWidth,
							childHeight,
							childDirection,
							size,
							nil,
							nil,
							flexInputs[size.node],
							baselineItemsRequired
						)
						if not child then
							return nil, failure or "missing-flex-scene-child"
						end
					end
					views[size.node] = size.node
				end
				return views, nil
			end
			local function placeItems(
				placement: ListLayout.Plan,
				views: { [Types.Node]: SceneTypes.Key },
				parentKey: Types.Node
			): string?
				if not placement.manual then
					lists[parentKey] = { plan = placement, views = views }
					return nil
				end
				local offsets, failure = ListLayout.offsets(placement)
				if not offsets then
					return failure
				end
				for item, point in offsets do
					local child = plan.boxes[views[item]]
					child.x, child.y = point.x, point.y
				end
				return nil
			end
			if flex.lines then
				local cache = lineNodes[node]
				if not cache then
					cache = setmetatable({}, { __mode = "v" })
					lineNodes[node] = cache
				end
				for index, line in flex.lines do
					local lineNode = cache[index]
					if not lineNode then
						local created: Types.Node = {
							tag = "#flex-line",
							className = "",
							classes = {},
							attributes = {},
							states = {},
							text = "",
							children = {},
							parent = node,
						}
						lineNode = created
						cache[index] = created
					end
					local lineStyle: Types.ComputedStyle = {
						properties = { display = { { kind = "word", value = "block" } } },
						variables = {},
						unresolvedVariables = {},
						priorities = {},
						unresolved = {},
					}
					privateStyles[lineNode] = lineStyle
					local lineMetrics, failure = BoxModel.resolveMetrics(
						lineStyle,
						{ lengths = units, containingInlineSize = inline.contentWidth }
					)
					if not lineMetrics then
						return nil, failure
					end
					rank += 1
					plan.boxes[lineNode] = {
						node = lineNode,
						owner = node,
						parent = node,
						x = 0,
						y = line.y,
						width = inline.contentWidth,
						height = line.placement.height,
						metrics = lineMetrics,
						lengths = units,
						zIndex = rank,
					}
					local views, renderFailure = renderItems(line.used, lineNode, anonymous)
					if not views then
						return nil, renderFailure
					end
					local placementFailure = placeItems(line.placement, views, lineNode)
					if placementFailure then
						return nil, placementFailure
					end
				end
			else
				local views, renderFailure = renderItems(flex.used, node, anonymous)
				if not views then
					return nil, renderFailure
				end
				local placementFailure = placeItems(flex.placement, views, node)
				if placementFailure then
					return nil, placementFailure
				end
			end
			box.height = flexBlock.height
			if #flex.used == 1 and not flex.lines then
				local item = plan.boxes[flex.used[1].node]
				local offsets, failure = ListLayout.offsets(flex.placement)
				if not offsets then
					return nil, failure
				end
				local placement = offsets[item.node]
				-- With one item the startmost/endmost baseline sources coincide.
				-- Empty items synthesize from their border edges; unmeasured text
				-- retains its present-but-unknown baseline set instead.
				box.baselines = shiftedBaselines(
					item.baselines or { first = item.height, last = item.height },
					metrics.border.top + metrics.padding.top + placement.y
				)
			elseif #flex.used > 0 then
				-- Ordering, reversal and baseline-sharing groups still require
				-- qualification before publishing multi-item flex baselines.
				box.baselines = {}
			end
			if not parent then
				box.y = flexBlock.marginTop
			end
			plan.boxes[node] = box
			if after then
				table.insert(positioned, { node = after, parent = node })
			end
			local flow = BlockFlow.resolve({}, {
				marginTop = flexBlock.marginTop,
				marginBottom = flexBlock.marginBottom,
				collapseTop = false,
				collapseBottom = false,
				canCollapseThrough = false,
				minimumContentHeight = 0,
			})
			return finish({ box = box, flow = flow })
		end
		local children: { Layout } = {}
		local flowChildren: { BlockFlow.Child } = {}
		local hasTextLine = false
		local atomicChildren = false
		for _, child in nodeChildren do
			local childStyle = snapshot.styles[child]
			if childStyle and keyword(childStyle, "position", "static") ~= "absolute" and keyword(childStyle, "position", "static") ~= "fixed" then
				local childDisplay = Display.resolve(childStyle)
				if childDisplay == "inline-flex" then
					atomicChildren = true
					break
				end
			end
		end
		if atomicChildren and textAtoms then
			return nil, "mixed-text-atomic-inline-provider-required"
		end
		if textAtoms then
			if not settings.fonts then
				return nil, "block-scene-text-font-provider-required"
			end
			local text, textFailure = TextParagraph.resolve(node, style, textAtoms, {
				width = inline.contentWidth,
				fonts = settings.fonts,
				fontMetrics = if settings.fontMetrics
					then settings.fontMetrics(style)
					else settings.fonts:getMetrics(style),
				measureText = snapshot.measureText,
				geometry = settings.textGeometry,
				nativeTextLine = settings.nativeTextLine,
			})
			if not text then
				return nil, textFailure
			end
			box.runs = text.runs
			if text.baselines then
				box.baselines = shiftedBaselines(text.baselines, metrics.border.top + metrics.padding.top)
			end
			if text.lineCount > 0 then
				hasTextLine = true
				table.insert(flowChildren, {
					height = text.height,
					top = BlockFlow.margin(0),
					bottom = BlockFlow.margin(0),
					beforeBottom = BlockFlow.margin(0),
					through = false,
				})
			end
		end
		local childFlowOffset = #flowChildren
		if atomicChildren then
			local items: { AtomicInline.Item } = {}
			local pending = false
			for _, child in nodeChildren do
				local childSource = snapshot.styles[child]
				if not childSource then
					return nil, "missing-atomic-inline-child-style"
				end
				local physical, failure = LogicalProperties.view(childSource)
				if not physical then
					return nil, failure
				end
				local childDisplay, childDisplayFailure = Display.resolve(physical)
				if not childDisplay then
					return nil, childDisplayFailure
				end
				local childPosition = keyword(physical, "position", "static")
				if childDisplay == "none" then
					continue
				end
				if childPosition == "absolute" then
					local _, reason = visit(child, node, inline.contentWidth, childHeight, childDirection, nil)
					if reason then
						return nil, reason
					end
					continue
				end
				if childDisplay ~= "inline-flex" then
					return nil, "mixed-block-atomic-inline-provider-required"
				end
				local prepared, reason = AtomicInline.prepare(
					child,
					physical,
					snapshot,
					lengths(physical, snapshot, settings, rootLengths.fontSize, rootLengths.lineHeight),
					inline.contentWidth,
					childHeight,
					intrinsic
				)
				if reason == "pending-text-measurement" then
					pending = true
					continue
				end
				if not prepared then
					return nil, reason
				end
				local layout, layoutFailure = visit(child, node, inline.contentWidth, childHeight, childDirection, {
					width = prepared.width,
					height = prepared.height,
					widthDefinite = true,
					heightDefinite = prepared.heightDefinite,
				}, nil, nil, nil, true)
				if layoutFailure == "pending-text-measurement" then
					pending = true
					continue
				end
				if not layout then
					return nil, layoutFailure or "missing-atomic-inline-child-box"
				end
				table.insert(items, { prepared = prepared, box = layout.box })
			end
			if pending then
				return nil, "pending-text-measurement"
			end
			local fontMetrics = if settings.fontMetrics
				then settings.fontMetrics(style)
				elseif settings.fonts then settings.fonts:getMetrics(style)
				else nil
			local line, failure = AtomicInline.resolve(items, style, inline.contentWidth, fontMetrics)
			if not line then
				return nil, failure
			end
			for _, placement in line.placements do
				local childBox = plan.boxes[placement.node]
				childBox.x, childBox.y = placement.x, placement.y
			end
			if line.baselines then
				box.baselines = shiftedBaselines(line.baselines, metrics.border.top + metrics.padding.top)
			end
			hasTextLine = #items > 0
			if hasTextLine then
				table.insert(flowChildren, {
					height = line.height,
					top = BlockFlow.margin(0),
					bottom = BlockFlow.margin(0),
					beforeBottom = BlockFlow.margin(0),
					through = false,
				})
			end
		else
			local pending = false
			for _, child in nodeChildren do
				local laidOut, failure = visit(
					child,
					node,
					inline.contentWidth,
					childHeight,
					childDirection,
					nil,
					nil,
					nil,
					nil,
					baselineRequired
				)
				if failure == "pending-text-measurement" then
					pending = true
					continue
				elseif failure then
					return nil, failure
				end
				if laidOut then
					table.insert(children, laidOut)
					table.insert(flowChildren, {
						height = laidOut.box.height,
						top = laidOut.flow.top,
						bottom = laidOut.flow.bottom,
						through = laidOut.flow.through,
						beforeBottom = laidOut.flow.beforeBottom,
					})
				end
			end
			if pending then
				return nil, "pending-text-measurement"
			end
		end
		local flow = BlockFlow.resolve(flowChildren, {
			marginTop = preliminary.marginTop,
			marginBottom = preliminary.marginBottom,
			collapseTop = not hasTextLine
				and not establishesFormattingContext
				and metrics.border.top == 0
				and metrics.padding.top == 0,
			collapseBottom = not hasTextLine
				and not establishesFormattingContext
				and preliminary.automatic
				and metrics.border.bottom == 0
				and metrics.padding.bottom == 0,
			canCollapseThrough = not hasTextLine
				and not preliminary.ratioDependent
				and not establishesFormattingContext
				and metrics.verticalInset == 0
				and preliminary.minimumContentHeight == 0
				and (preliminary.preferredContentHeight == nil or preliminary.preferredContentHeight == 0),
			minimumContentHeight = preliminary.minimumContentHeight,
		})
		local block: BlockSizing.BlockSize? = preliminary
		local blockFailure: string?
		if not assigned then
			block, blockFailure = BlockSizing.resolveBlock(style, metrics, {
				width = inline.contentWidth,
				height = height,
				autoContentHeight = editorContentHeight or flow.contentHeight,
				lengths = units,
				minContentHeight = if emptyContent then 0 else editorContentHeight,
			})
		end
		if not block then
			return nil, blockFailure
		end
		box.height = block.height
		for index, child in children do
			child.box.y = flow.positions[index + childFlowOffset]
			if child.box.baselines then
				local shifted =
					shiftedBaselines(child.box.baselines, metrics.border.top + metrics.padding.top + child.box.y)
				if box.baselines then
					box.baselines.last = shifted.last
				else
					box.baselines = shifted
				end
			end
		end
		if not parent then
			box.y = block.marginTop
		end
		plan.boxes[node] = box
		if after then
			table.insert(positioned, { node = after, parent = node })
		end
		return finish({ box = box, flow = flow })
	end
	measureAtWidth = function(request: FlexScene.Request, contentWidth: number): (FlexTypes.Size?, string?)
		if contentWidth ~= contentWidth or contentWidth < 0 or contentWidth == math.huge then
			return nil, "invalid-block-measurement-width"
		end
		local parent, parentFailure = BoxChildren.parent(request.node, snapshot)
		if parentFailure then
			return nil, parentFailure
		end
		local parentDirection = rootDirection
		if parent then
			local parentStyle = snapshot.styles[parent]
			if not parentStyle then
				return nil, "missing-block-intrinsic-parent-style"
			end
			local direction, failure = keyword(parentStyle, "direction", "ltr")
			if not direction then
				return nil, failure
			end
			parentDirection = direction
		end
		local cached = blockMeasurements[request.node]
		if cached then
			for _, entry in cached do
				if
					entry.width == contentWidth
					and entry.containingWidth == request.width
					and entry.containingHeight == request.height
					and entry.direction == parentDirection
					and entry.absolute == request.absolute
				then
					return entry.result, entry.failure
				end
			end
		else
			cached = {}
			blockMeasurements[request.node] = cached
		end
		-- Reuse the formatter with a fixed used width and an automatic height.
		-- Scratch geometry, paint order and out-of-flow queues never enter the
		-- final scene. Native instances are created only after the full plan.
		local previousPlan, previousLists, previousStyles = plan, lists, privateStyles
		local previousRank, previousPositioned = rank, positioned
		lists = {}
		privateStyles = {}
		plan = { boxes = {}, lists = lists, styles = privateStyles }
		positioned = {}
		rank = 0
		local ok, layout, reason = pcall(function(): (Layout?, string?)
			return visit(
				request.node,
				parent,
				request.width,
				request.height,
				parentDirection,
				nil,
				request.absolute,
				contentWidth + request.metrics.horizontalInset,
				request
			)
		end)
		plan, lists, privateStyles = previousPlan, previousLists, previousStyles
		rank, positioned = previousRank, previousPositioned
		local result: FlexTypes.Size? = nil
		local failure: string? = nil
		if not ok then
			failure = `block-intrinsic-measurement:{tostring(layout)}`
		elseif not layout then
			failure = reason or "missing-block-intrinsic-layout"
		elseif layout.box.height ~= layout.box.height or layout.box.height == math.huge then
			failure = "block-intrinsic-height-overflow"
		else
			result =
				{ width = contentWidth, height = math.max(0, layout.box.height - layout.box.metrics.verticalInset) }
		end
		-- A live resizable parent must not retain every historical width.
		if #cached == 8 then
			table.remove(cached, 1)
		end
		table.insert(cached, {
			width = contentWidth,
			containingWidth = request.width,
			containingHeight = request.height,
			direction = parentDirection,
			absolute = request.absolute,
			result = result,
			failure = failure,
		})
		return result, failure
	end
	local flowVersion = if forwardInputs
			and defaultProjection
			and generatedCache
			and generatedCache.measurements
		then BlockMeasurements.flowVersion(generatedCache.measurements, root)
		else nil
	local previousFlow = generatedCache and generatedCache.flow
	if generatedCache then
		generatedCache.flow = nil
	end
	local rootLayout: Layout? = nil
	local reusedFlow = false
	local failure: string? = nil
	if previousFlow and flowVersion then
		local nextRank: number?
		rootLayout, nextRank, failure = FlowFragments.restore(
			previousFlow,
			flowVersion,
			plan,
			snapshot,
			settings.imageContentSource,
			function(origin, name)
				return pseudoFragment(origin, name, previousFlow)
			end,
			generatedOwners,
			positioned,
			settings.immutableFragments
		)
		if rootLayout then
			rank = assert(nextRank)
			reusedFlow = true
		elseif not failure then
			table.clear(plan.boxes)
			table.clear(lists)
			table.clear(privateStyles)
			table.clear(generatedOwners)
			table.clear(projectedChildren)
			table.clear(positioned)
		end
	end
	if not rootLayout and not failure then
		rootLayout, failure = visit(root, nil, snapshot.viewport.X, snapshot.viewport.Y, rootDirection, nil)
	end
	if failure then
		return nil, failure
	end
	local nextFlow = if reusedFlow
		then previousFlow
		elseif flowVersion and rootLayout then FlowFragments.capture(
			flowVersion,
			rootLayout,
			plan,
			rank,
			snapshot,
			settings.immutableFragments
		)
		else nil
	local nextPositionedSizing: PositionedSizing.Cache? = if forwardInputs and snapshot.layoutRevision ~= nil
		then {}
		else nil
	local previousPositionedSizing = if generatedCache
			and generatedCache.positionedEpoch == snapshot.layoutRevision
		then generatedCache.positionedSizing
		else nil
	local origins: { [SceneTypes.Key]: RelativePosition.Offset } = {}
	local translations: { [SceneTypes.Key]: TranslationTransform.Result } = {}
	local listOffsets: { [SceneTypes.Key]: { [Types.Node]: RelativePosition.Offset } } = {}
	local function translation(key: SceneTypes.Key): (TranslationTransform.Result?, string?)
		if translations[key] then
			return translations[key], nil
		end
		local box = plan.boxes[key]
		local style = box and (snapshot.styles[box.node] or privateStyles[box.node])
		if not box or not style then
			return nil, "transform-containing-geometry-required"
		end
		local value, reason =
			TranslationTransform.resolve(style, BoxModel.fromBorderBox(box.metrics, box.width, box.height), box.lengths)
		if value then
			translations[key] = value
		end
		return value, reason
	end
	local function origin(key: SceneTypes.Key?): (RelativePosition.Offset?, string?)
		if key == nil then
			return { x = 0, y = 0 }, nil
		end
		if origins[key] then
			return origins[key], nil
		end
		local box = plan.boxes[key]
		if not box then
			return nil, "absolute-render-parent-geometry-required"
		end
		local parentOrigin, reason = origin(box.parent)
		if not parentOrigin then
			return nil, reason
		end
		local parent = if box.parent ~= nil then plan.boxes[box.parent] else nil
		local transformed, transformFailure = translation(key)
		if not transformed then
			return nil, transformFailure
		end
		local x, y = box.x, box.y
		local list = if box.parent ~= nil then lists[box.parent] else nil
		if list and not box.outOfFlow then
			local offsets = listOffsets[box.parent :: SceneTypes.Key]
			if not offsets then
				local resolved, offsetFailure = ListLayout.offsets(list.plan)
				if not resolved then
					return nil, offsetFailure
				end
				offsets = resolved
				listOffsets[box.parent :: SceneTypes.Key] = resolved
			end
			local placed = offsets[box.node]
			if not placed then
				return nil, "absolute-list-item-position-required"
			end
			x, y = placed.x, placed.y
		end
		local point = {
			x = parentOrigin.x + x + (box.offsetX or 0) + transformed.x + (if parent
				then parent.metrics.border.left + parent.metrics.padding.left
				else 0),
			y = parentOrigin.y + y + (box.offsetY or 0) + transformed.y + (if parent
				then parent.metrics.border.top + parent.metrics.padding.top
				else 0),
		}
		origins[key] = point
		return point, nil
	end
	local resolvePositioned: ({ Positioned }) -> string?
	resolvePositioned = function(entries: { Positioned }): string?
		for _, entry in entries do
			local source = snapshot.styles[entry.node]
			if not source then
				return "absolute-style-required"
			end
			local ancestor = if keyword(source, "position", "static") == "fixed" then nil else entry.node.parent
			local containing: SceneTypes.Box? = nil
			local containingOrigin = { x = 0, y = 0 }
			local containingWidth, containingHeight = snapshot.viewport.X, snapshot.viewport.Y
			local containingDirection = rootDirection
			while ancestor do
				local ancestorStyle = snapshot.styles[ancestor]
				if not ancestorStyle then
					return "absolute-containing-style-required"
				end
				local ancestorDisplay, displayFailure =
					Display.forNode(ancestorStyle, ancestor, snapshot.roots[1] == ancestor)
				if not ancestorDisplay then
					return displayFailure
				end
				if ancestorDisplay == "contents" then
					ancestor = ancestor.parent
					continue
				end
				for name, initial in containingDefaults do
					if keyword(ancestorStyle, name, initial) ~= initial then
						return `absolute-containing-block-provider-required:{name}`
					end
				end
				local position, reason = keyword(ancestorStyle, "position", "static")
				if not position then
					return reason
				end
				local transformed, transformFailure = translation(ancestor)
				if not transformed then
					return transformFailure
				end
				local motions = snapshot.animations
				local motion = if motions then motions[ancestor] else nil
				local requirements = snapshot.transformTransitions
				local requirement = if requirements then requirements[ancestor] else nil
				if
					position ~= "static"
					or transformed.establishesContext
					or (requirement ~= nil and requirement.context)
					or (motion and (motion.rotationNeeded or motion.translationNeeded or motion.scaleNeeded))
				then
					containing = plan.boxes[ancestor]
					if not containing then
						return "positioned-containing-box-required"
					end
					local point, pointFailure = origin(ancestor)
					if not point then
						return pointFailure
					end
					containingOrigin =
						{ x = point.x + containing.metrics.border.left, y = point.y + containing.metrics.border.top }
					containingWidth = containing.width
						- containing.metrics.border.left
						- containing.metrics.border.right
					containingHeight = containing.height
						- containing.metrics.border.top
						- containing.metrics.border.bottom
					local direction, directionFailure = keyword(ancestorStyle, "direction", "ltr")
					if not direction then
						return directionFailure
					end
					containingDirection = direction
					break
				end
				ancestor = ancestor.parent
			end
			local units = lengths(source, snapshot, settings, rootLengths.fontSize, rootLengths.lineHeight)
			local content = keyword(source, "content", "normal")
			local noFlowChildren, childrenFailure = emptyChildren(entry.node, snapshot)
			if noFlowChildren == nil then
				return childrenFailure
			end
			local emptyFlow = entry.node.text == ""
				and not TextSegments.has(entry.node.textAfter)
				and noFlowChildren
				and (content == "normal" or content == "none")
			-- Zero intrinsic flow is not an immutable leaf: positioned children
			-- still change and must be collected from the current tree.
			local emptyLeaf = emptyFlow and #entry.node.children == 0
			local absoluteContext: AbsolutePosition.Context = {
				width = containingWidth,
				height = containingHeight,
				direction = containingDirection,
				lengths = units,
				replaced = entry.node.tag == "img" or entry.node.tag == "input" or entry.node.tag == "textarea",
				minContentWidth = if emptyFlow then 0 else nil,
				maxContentWidth = if emptyFlow then 0 else nil,
				autoContentHeight = if emptyFlow then 0 else nil,
			}
			local metrics, used, usedFailure, sizingToken = PositionedSizing.resolve(
				previousPositionedSizing,
				nextPositionedSizing,
				entry.node,
				source,
				absoluteContext
			)
			if not metrics then
				return usedFailure
			end
			if not used then
				local function resolveUsed(): (AbsolutePosition.Rect?, string?)
					local resolved, reason = AbsolutePosition.resolve(source, metrics, absoluteContext)
					if reason == "absolute-shrink-to-fit-contributions-required" then
						local contribution, why = intrinsic({
							node = entry.node, style = source, metrics = metrics, lengths = units,
							snapshot = snapshot, width = containingWidth, height = containingHeight,
							widthDefinite = true, flow = "row", inlineSizeRequired = true, absolute = true,
						})
						if not contribution then return nil, why end
						absoluteContext.minContentWidth = contribution.minContentWidth
						absoluteContext.maxContentWidth = contribution.maxContentWidth
						resolved, reason = AbsolutePosition.resolve(source, metrics, absoluteContext)
					end
					if reason ~= "absolute-content-height-provider-required" then
						return resolved, reason
					end
					-- The inline axis is already resolved. Measure ordinary contents at
					-- that used width with the existing scratch block/flex formatter;
					-- only then apply the subject's block min/max constraints/insets.
					local probe = table.clone(absoluteContext)
					probe.autoContentHeight = 0
					local inline, inlineFailure = AbsolutePosition.resolve(source, metrics, probe)
					if not inline then
						return nil, inlineFailure
					end
					local measure: (FlexScene.Request, number) -> (FlexTypes.Size?, string?) =
						assert(measureAtWidth, "block measurement formatter is not initialized")
					local contentSize, contentFailure = measure({
						node = entry.node,
						style = source,
						metrics = metrics,
						lengths = units,
						snapshot = snapshot,
						width = containingWidth,
						height = containingHeight,
						widthDefinite = true,
						flow = "row",
						inlineSizeRequired = false,
						absolute = true,
					}, math.max(0, inline.width - metrics.horizontalInset))
					if not contentSize then
						return nil, contentFailure
					end
					absoluteContext.autoContentHeight = contentSize.height
					return AbsolutePosition.resolve(source, metrics, absoluteContext)
				end
				if not used and (usedFailure == "absolute-content-height-provider-required" or usedFailure == "absolute-shrink-to-fit-contributions-required") then
					used, usedFailure = resolveUsed()
				end
				if
					not used
					and (
						usedFailure == "absolute-static-position-provider-required:width"
						or usedFailure == "absolute-static-position-provider-required:height"
					)
				then
					local physical, physicalFailure = LogicalProperties.view(source)
					if not physical then
						return physicalFailure
					end
					local function automaticInset(name: string): boolean
						local tokens = physical.properties[name]
						return not physical.unresolved[name]
							and (
								tokens == nil
								or (
									#tokens == 1
									and tokens[1].kind == "word"
									and string.lower(tokens[1].value) == "auto"
								)
							)
					end
					local staticX = automaticInset("left") and automaticInset("right")
					local staticY = automaticInset("top") and automaticInset("bottom")
					local staticParent = if entry.parent then plan.boxes[entry.parent] else nil
					local parentStyle = if staticParent then snapshot.styles[staticParent.node] else nil
					local parentDisplay = if parentStyle then Display.resolve(parentStyle) else nil
					if
						(staticX or staticY)
						and staticParent
						and parentStyle
						and (parentDisplay == "flex" or parentDisplay == "inline-flex")
					then
						-- Resolve supported used sizes first. Missing intrinsic/replaced
						-- sizes still fail explicitly; no guessed size enters alignment.
						absoluteContext.staticLeft, absoluteContext.staticRight, absoluteContext.staticTop = 0, 0, 0
						local sized, sizeFailure = resolveUsed()
						if not sized then
							return sizeFailure
						end
						local point, pointFailure = FlexStaticPosition.resolve(
							parentStyle,
							physical,
							entry.node,
							metrics,
							sized.width,
							sized.height,
							{
								width = staticParent.width - staticParent.metrics.horizontalInset,
								height = staticParent.height - staticParent.metrics.verticalInset,
								lengths = staticParent.lengths,
							}
						)
						if not point then
							return pointFailure
						end
						local parentOrigin, originFailure = origin(entry.parent)
						if not parentOrigin then
							return originFailure
						end
						local x = parentOrigin.x
							+ staticParent.metrics.border.left
							+ staticParent.metrics.padding.left
							+ point.x
							- containingOrigin.x
						local y = parentOrigin.y
							+ staticParent.metrics.border.top
							+ staticParent.metrics.padding.top
							+ point.y
							- containingOrigin.y
						local left, right, top = metrics.margin.left, metrics.margin.right, metrics.margin.top
						local leftMargin, rightMargin, topMargin = left.value, right.value, top.value
						if left.auto then
							leftMargin = 0
						end
						if right.auto then
							rightMargin = 0
						end
						if top.auto then
							topMargin = 0
						end
						absoluteContext.staticLeft = x - leftMargin
						absoluteContext.staticRight = containingWidth - x - sized.width - rightMargin
						absoluteContext.staticTop = y - topMargin
					elseif staticParent and entry.parent then
						local parentOrigin, originFailure = origin(entry.parent)
						if not parentOrigin then return originFailure end
						local x = parentOrigin.x + staticParent.metrics.border.left + staticParent.metrics.padding.left - containingOrigin.x
						local y = parentOrigin.y + staticParent.metrics.border.top + staticParent.metrics.padding.top - containingOrigin.y
						absoluteContext.staticLeft = x
						absoluteContext.staticRight = containingWidth - x - (staticParent.width - staticParent.metrics.horizontalInset)
						absoluteContext.staticTop = y
					else
						absoluteContext.staticLeft, absoluteContext.staticRight, absoluteContext.staticTop = 0, 0, 0
					end
					used, usedFailure = resolveUsed()
				end
			end
			if not used then
				return usedFailure
			end
			local assigned: AssignedSize = {
				width = used.width,
				height = used.height,
				widthDefinite = used.widthDefinite,
				heightDefinite = used.heightDefinite,
			}
			-- Used-size identity includes the complete unit/containing context.
			-- Empty positioned boxes can reuse ordinary fragment formatting too;
			-- pseudo styles and image content remain current inputs. Placement,
			-- containing-block discovery and native validation still run normally.
			local fragments: { FormattingFragments.Entry }? = nil
			if
				sizingToken
				and defaultProjection
				and emptyLeaf
				and entry.node.tag ~= "img"
				and entry.node.tag ~= "input"
				and entry.node.tag ~= "textarea"
			then
				local pseudoStyle = snapshot.pseudoStyle
				local before = if pseudoStyle then pseudoStyle(entry.node, "before") else nil
				local after = if pseudoStyle then pseudoStyle(entry.node, "after") else nil
				local retained = previousPositionedFragments
				local previous = if retained then retained[sizingToken] else nil
				local record: PositionedFragment = {
					before = before,
					after = after,
					entries = if previous
							and previous.before == before
							and previous.after == after
						then table.clone(previous.entries)
						else {},
				}
				nextPositionedFragments[sizingToken] = record
				fragments = record.entries
			end
			local laidOut, layoutFailure = visit(
				entry.node,
				entry.parent,
				containingWidth,
				containingHeight,
				containingDirection,
				assigned,
				true,
				nil,
				if forwardInputs then { metrics = metrics, lengths = units, fragments = fragments } else nil
			)
			if not laidOut then
				return layoutFailure or "absolute-layout-required"
			end
			local parentOrigin, parentFailure = origin(entry.parent)
			if not parentOrigin then
				return parentFailure
			end
			local parentBox = if entry.parent then plan.boxes[entry.parent] else nil
			local parentContentX = parentOrigin.x
				+ (if parentBox then parentBox.metrics.border.left + parentBox.metrics.padding.left else 0)
			local parentContentY = parentOrigin.y
				+ (if parentBox then parentBox.metrics.border.top + parentBox.metrics.padding.top else 0)
			laidOut.box.x, laidOut.box.y =
				used.x + containingOrigin.x - parentContentX, used.y + containingOrigin.y - parentContentY
			laidOut.box.offsetX, laidOut.box.offsetY = 0, 0
			local descendants = positioned
			positioned = {}
			local reason = resolvePositioned(descendants)
			if reason then
				return reason
			end
		end
		return nil
	end
	local pending = positioned
	positioned = {}
	local positionedFailure = resolvePositioned(pending)
	if not positionedFailure then
		positionedFailure = PositionedPaintOrder.apply(plan, snapshot.styles)
	end
	if not positionedFailure and generatedCache then
		generatedCache.flow = nextFlow
		generatedCache.positionedSizing = nextPositionedSizing
		generatedCache.positionedFragments = nextPositionedFragments
		generatedCache.positionedEpoch = snapshot.layoutRevision
	end
	return if positionedFailure then nil else plan, positionedFailure
end

function BlockScene.create(options: Options?): SceneTypes.Provider
	local defaults: Options = options or {}
	local settings = table.clone(defaults)
	if settings.units then
		settings.units = table.clone(settings.units)
	end
	-- Weak keys and values: the committed renderer holds active fragment nodes;
	-- removed text does not retain its former logical parent through this cache.
	local anonymousCache: AnonymousCache = setmetatable({}, { __mode = "kv" })
	local generatedCache: GeneratedCache = {
		before = setmetatable({}, { __mode = "kv" }),
		after = setmetatable({}, { __mode = "kv" }),
		-- Custom intrinsic/replaced-image providers can read outside the subtree.
		-- Image content only paints an already sized box and remains live in the
		-- final formatting pass. It does not supply intrinsic geometry.
		measurements = if not settings.flexIntrinsic
				and not settings.imageSource
				and not settings.editorBaselines
			then BlockMeasurements.create()
			else nil,
	}
	return function(snapshot)
		return BlockScene.resolve(snapshot, settings, anonymousCache, generatedCache)
	end
end

return BlockScene
