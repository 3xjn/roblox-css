--!strict

local Types = require(script.Parent.Types)
local Fonts = require(script.Parent.Fonts)
local SceneTypes = require(script.Parent.SceneTypes)
local ScenePreparation = require(script.Parent.ScenePreparation)
local NativeBox = require(script.Parent.NativeBox)
local NativeText = require(script.Parent.NativeText)
local NativeList = require(script.Parent.NativeList)
local NativeEditor = require(script.Parent.NativeEditor)
local NativeClip = require(script.Parent.NativeClip)
local SceneBounds = require(script.Parent.SceneBounds)
local NativeDimensions = require(script.Parent.NativeDimensions)
local NativeScalarTransition = require(script.Parent.NativeScalarTransition)
local Profiler = require(script.Parent.Profiler)
local WorkQueue = require(script.Parent.WorkQueue)
local NativeAnimations = require(script.Parent.NativeAnimations)
local SceneAnimations = require(script.Parent.SceneAnimations)
local AnimationValues = require(script.Parent.AnimationValues)
local SceneTransforms = require(script.Parent.SceneTransforms)
local TransformValues = require(script.Parent.TransformValues)
local NativeValueTransition = require(script.Parent.NativeValueTransition)
local Playback = require(script.Parent.Playback)
local ShadowTransition = require(script.Parent.ShadowTransition)
local BoxModel = require(script.Parent.BoxModel)
local ResolvedStyle = require(script.Parent.ResolvedStyle)

type Record = {
	node: Types.Node,
	box: NativeBox.Box,
	runs: { [SceneTypes.RunKey]: NativeText.View },
	carrier: Frame?,
	group: NativeClip.View?,
	opacity: NativeScalarTransition.Controller?,
	opacityValue: number?,
	paint: NativeBox.Prepared?,
	paintVisible: boolean?,
	position: UDim2?,
	rank: number?,
	rotation: number?,
	scale: UIScale?,
	animations: NativeAnimations.Controller?,
	base: ScenePreparation.Box?,
	listMember: boolean?,
	transform: NativeValueTransition.Controller<TransformValues.Value>?,
	transformBase: SceneTransforms.Base?,
	transformPaint: ((TransformValues.Value) -> ())?,
	geometry: BoxModel.Geometry?,
	metrics: BoxModel.Metrics?,
	privateStyle: boolean?,
}
type ListRecord = {
	source: SceneTypes.List,
	layout: NativeList.Layout,
	views: { [Types.Node]: GuiObject },
}
export type Options = {
	onProfile: Profiler.Sink?,
	systemColors: { [string]: Types.RgbaColor }?,
	onDiagnostic: (string) -> (),
	onInvalidated: () -> (),
	onPaintInvalidated: (() -> ())?,
	-- Legacy/direct renderers observe painted ink. The host can omit this
	-- observer when its scene consumes requested geometry instead.
	observeTextBounds: boolean?,
}

-- Formatter-owned list plans are immutable. Compare their flat input records,
-- including unknown future fields, before retaining a prior native allocation.
local function sameFields(a: { [string]: unknown }, b: { [string]: unknown }, skip: string?): boolean
	for name, value in a do
		if name == skip then
			continue
		end
		local other = b[name]
		if
			value ~= other
			or (type(value) == "number" and value == 0 and type(other) == "number" and 1 / value ~= 1 / other)
		then
			return false
		end
	end
	for name in b do
		if name ~= skip and a[name] == nil then
			return false
		end
	end
	return true
end
local function sameListPlan(a: SceneTypes.List, b: SceneTypes.List): boolean
	if a == b then
		return true
	end
	local before, after = a.plan, b.plan
	if
		not sameFields(before :: { [string]: unknown }, after :: { [string]: unknown }, "items")
		or #before.items ~= #after.items
	then
		return false
	end
	for index, item in before.items do
		if not sameFields(item :: { [string]: unknown }, after.items[index] :: { [string]: unknown }, nil) then
			return false
		end
	end
	return true
end

local SceneRenderer = {}
SceneRenderer.__index = SceneRenderer

-- These memos belong to this renderer's current preparation inputs. Weak keys
-- alone let superseded plans/styles accumulate until a collector pass. Retained
-- native bases have separate ownership through the current box cache/records.
local function retainInputs(
	plan: SceneTypes.Plan,
	snapshot: SceneTypes.Snapshot,
	paint: ScenePreparation.PaintCache,
	glyphs: ScenePreparation.GlyphCache,
	previous: ScenePreparation.BoxCache?
)
	local boxes, styles = {}, {}
	for _, box in plan.boxes do
		boxes[box] = true
	end
	for _, style in snapshot.styles do
		styles[style] = true
	end
	for _, style in plan.styles or {} do
		styles[style] = true
	end
	-- Placeholder styles come from the preparation callback, outside those maps.
	-- Keep the last prepared inputs without invoking that callback a second time.
	for _, entry in if previous then previous.entries else {} do
		if entry.placeholder then
			styles[entry.placeholder] = true
		end
	end
	for box in paint do
		if not boxes[box] then
			paint[box] = nil
		end
	end
	for style in glyphs do
		if not styles[style] then
			glyphs[style] = nil
		end
	end
end

local function releaseAnimations(record: Record, animations: { [Types.Node]: NativeAnimations.Controller })
	if record.animations then
		if animations[record.node] == record.animations then
			animations[record.node] = nil
		end
		record.animations:destroy()
		record.animations = nil
		record.rotation = nil
		record.position = nil
	end
end
local function dispose(
	record: Record,
	owners: { [Instance]: Types.Node },
	animations: { [Types.Node]: NativeAnimations.Controller }
)
	releaseAnimations(record, animations)
	record.base, record.listMember = nil, nil
	if record.transform then
		record.transform:destroy()
		record.transform = nil
	end
	record.transformBase, record.transformPaint, record.geometry, record.metrics = nil, nil, nil, nil
	if record.opacity then
		record.opacity:destroy()
		record.opacity = nil
	end
	for _, run in record.runs do
		owners[run.label] = nil
		run:destroy()
	end
	table.clear(record.runs)
	owners[record.box.frame] = nil
	record.box:destroy()
	if record.group then
		record.group:destroy()
		record.group = nil
	end
	if record.carrier then
		record.carrier:Destroy()
		record.carrier = nil
	end
end

local function carrier(): Frame
	local frame = Instance.new("Frame")
	frame.Name = "CssLayoutSlot"
	frame.AnchorPoint = Vector2.zero
	frame.Position = UDim2.fromOffset(0, 0)
	frame.Size = UDim2.fromOffset(0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.None
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = false
	frame.Active = false
	frame.Selectable = false
	frame.Visible = true
	return frame
end

function SceneRenderer.new(mount: Frame, fonts: Fonts.Provider, options: Options): Renderer
	local probeFrame = Instance.new("Frame")
	probeFrame.Name = "TextCapabilityProbe"
	probeFrame.Visible = false
	probeFrame.Size = UDim2.fromOffset(0, 0)
	probeFrame.BackgroundTransparency = 1
	probeFrame.BorderSizePixel = 0
	probeFrame.Parent = mount
	local self: Renderer = setmetatable({
		_mount = mount,
		_fonts = fonts,
		_options = options,
		_probeFrame = probeFrame,
		_probe = NativeText.create(probeFrame, options.onDiagnostic),
		_editorProbe = nil :: NativeEditor.View?,
		_records = {} :: { [SceneTypes.Key]: Record },
		_byNode = {} :: { [Types.Node]: Record },
		_fragmented = {} :: { [Types.Node]: boolean },
		_paintCache = setmetatable({}, { __mode = "k" }) :: ScenePreparation.PaintCache,
		_glyphCache = setmetatable({}, { __mode = "k" }) :: ScenePreparation.GlyphCache,
		_boxCache = nil :: ScenePreparation.BoxCache?,
		_listCache = nil :: { [SceneTypes.Key]: ListRecord }?,
		_owners = {} :: { [Instance]: Types.Node },
		_animations = {} :: { [Types.Node]: NativeAnimations.Controller },
		_lists = {} :: { [SceneTypes.Key]: NativeList.Layout },
		_destroyed = false,
		_committing = false,
		_paintRevision = nil :: number?,
		_contextSurface = nil :: LayerCollector?,
		_contextConnection = nil :: RBXScriptConnection?,
		_ancestryConnection = nil :: RBXScriptConnection?,
	}, SceneRenderer)
	self:_watchContext()
	self._ancestryConnection = mount.AncestryChanged:Connect(function()
		if self._destroyed then
			return
		end
		self:_watchContext()
		self._options.onInvalidated()
	end)
	return self
end

function SceneRenderer._watchContext(self: Renderer)
	if self._destroyed then
		return
	end
	local surface = self._mount:FindFirstAncestorWhichIsA("LayerCollector") :: LayerCollector?
	if surface == self._contextSurface then
		return
	end
	if self._contextConnection then
		self._contextConnection:Disconnect()
		self._contextConnection = nil
	end
	self._contextSurface = surface
	if surface then
		self._contextConnection = surface:GetPropertyChangedSignal("ZIndexBehavior"):Connect(function()
			if not self._destroyed then
				self._options.onInvalidated()
			end
		end)
	end
end

function SceneRenderer.measurements(self: Renderer): { [SceneTypes.Key]: { [SceneTypes.RunKey]: Vector2 } }
	local result: { [SceneTypes.Key]: { [SceneTypes.RunKey]: Vector2 } } = {}
	for key, record in self._records do
		local runs: { [SceneTypes.RunKey]: Vector2 } = {}
		for runKey, run in record.runs do
			runs[runKey] = run.label.TextBounds
		end
		result[key] = runs
	end
	return result
end

function SceneRenderer.getGuiObject(self: Renderer, key: SceneTypes.Key): GuiObject?
	local record = self._records[key]
	return if record then record.box.target else nil
end

function SceneRenderer.getLayoutBox(self: Renderer, key: SceneTypes.Key): BoxModel.Geometry?
	local record = self._records[key]
	return if record and record.geometry then table.clone(record.geometry) else nil
end

function SceneRenderer.getResolvedProperty(self: Renderer, key: SceneTypes.Key, name: string): (string?, string?)
	local record = self._records[key]
	if self._destroyed or not record or not record.geometry or not record.metrics or not record.transformBase then
		return nil, "resolved-style-target-not-committed"
	end
	if self._fragmented[record.node] then
		return nil, "resolved-style-multiple-fragments-provider-required"
	end
	local base = record.transformBase
	local opacity = if record.opacity then record.opacity:current() else record.opacityValue
	assert(opacity ~= nil, "committed-opacity-value-required")
	return ResolvedStyle.read({
		style = base.style,
		geometry = record.geometry,
		metrics = record.metrics,
		units = base.units,
		transform = if record.transform
			then function()
				return assert(record.transform):current()
			end
			else nil,
		animation = if record.animations
			then function(property)
				return assert(record.animations):current(property)
			end
			else nil,
		opacity = opacity,
	}, name)
end

-- Snapshot only on demand. Keyed paint fragments share their logical owner;
-- querying descendants walks the committed tree, never a recurring scan.
function SceneRenderer.getPlaybacks(self: Renderer, key: SceneTypes.Key, subtree: boolean?): { Playback.Handle }
	local selected = self._records[key]
	if self._destroyed or not selected then
		return {}
	end
	local owner = self._owners[selected.box.frame] or selected.node
	local result, seen = {}, {} :: { [Playback.Handle]: boolean }
	local function add(handle: Playback.Handle?)
		if handle and not seen[handle] then
			seen[handle] = true
			table.insert(result, handle)
		end
	end
	for _, record in self._records do
		local node: Types.Node? = self._owners[record.box.frame] or record.node
		if subtree then
			while node and node ~= owner do
				node = node.parent
			end
		end
		if node ~= owner then
			continue
		end
		if record.transform then
			add(record.transform:playback())
		end
		if record.opacity then
			add(record.opacity:playback())
		end
		if record.box._raster then
			add(ShadowTransition.playback(record.box._raster))
		end
		if record.animations then
			for _, handle in record.animations:playbacks() do
				add(handle)
			end
		end
	end
	return result
end

function SceneRenderer.animationTimes(self: Renderer, node: Types.Node, effects: { SceneAnimations.Effect }): { number }
	local controller = self._animations[node]
	return if controller and not controller._destroyed then controller:times(effects) else {}
end

function SceneRenderer.transformRequirement(
	self: Renderer,
	node: Types.Node,
	style: Types.ComputedStyle
): (SceneTransforms.Requirement?, string?)
	local record = self._byNode[node]
	if not record or record.box._destroyed then
		return nil, nil
	end
	local previous: Record = assert(record)
	local requirement, why = SceneTransforms.requirement(previous.transformBase, previous.transform, style)
	if requirement and self._fragmented[node] then
		return nil, "transform-transition-multiple-fragments-provider-required"
	end
	return requirement, why
end

function SceneRenderer.transformRequirements(
	self: Renderer,
	styles: { [Types.Node]: Types.ComputedStyle }
): ({ [Types.Node]: SceneTransforms.Requirement }?, string?)
	local requirements = {}
	for node, style in styles do
		local value, why = self:transformRequirement(node, style)
		if why then
			return nil, why
		end
		if value then
			requirements[node] = value
		end
	end
	-- Private generated nodes retain their last computed input for cache probes.
	-- Formatting replaces their requirement if the current pseudo style changed.
	for node, record in self._byNode do
		if record.privateStyle and styles[node] == nil and record.transformBase then
			local value, why = self:transformRequirement(node, record.transformBase.style)
			if why then
				return nil, why
			end
			if value then
				requirements[node] = value
			end
		end
	end
	return requirements, nil
end

function SceneRenderer.getImageLabel(self: Renderer, key: SceneTypes.Key): ImageLabel?
	local record = self._records[key]
	return if not self._destroyed and record then record.box:getImageLabel() else nil
end

function SceneRenderer.getOwner(self: Renderer, target: Instance): Types.Node?
	if self._destroyed or not target:IsDescendantOf(self._mount) then
		return nil
	end
	local current: Instance? = target
	while current and current ~= self._mount do
		local owner = self._owners[current]
		if owner then
			return owner
		end
		current = current.Parent
	end
	return nil
end

local function beginOpacity(self: Renderer, key: SceneTypes.Key, record: Record, previous: number)
	local motion = NativeScalarTransition.create(record.box.frame, "OpacityTransitionProgress", function(value)
		local group = record.group
		if group and not group._destroyed then
			group.group.GroupTransparency = 1 - value
		end
	end, function()
		if not self._destroyed and self._records[key] == record then
			(self._options.onPaintInvalidated or self._options.onInvalidated)()
		end
	end)
	record.opacity = motion
	motion:apply(previous, nil)
	return motion
end

local function beginTransform(
	self: Renderer,
	key: SceneTypes.Key,
	record: Record
): NativeValueTransition.Controller<TransformValues.Value>
	local motion = NativeValueTransition.create(record.box.frame, "TransformTransitionProgress", {
		equal = TransformValues.equal,
		interpolate = TransformValues.interpolate,
	}, function(value)
		if record.transformPaint then
			record.transformPaint(value)
		end
	end, function()
		if not self._destroyed and self._records[key] == record then
			(self._options.onPaintInvalidated or self._options.onInvalidated)()
		end
	end)
	record.transform = motion
	return motion
end

-- Preparation retains a base only while source geometry, inherited styles,
-- eligibility and resources match. Global clipping/list/bounds validation still
-- runs; controllers and compositing surfaces keep their ordinary commit path.
local function retainedView(
	record: Record?,
	box: ScenePreparation.Box,
	base: ScenePreparation.Box?,
	grouped: boolean
): boolean
	if not record or not base or record.box._destroyed then
		return false
	end
	local controlled = box.editor and box.editor.data.value
	if controlled ~= nil and (record.box.target :: TextBox).Text ~= controlled then
		return false
	end
	return record.base == base
		and record.paint == box.nativePaint
		and box.animation == nil
		and record.animations == nil
		and record.transform == nil
		and box.transformTransition == nil
		and not box.opacitySurface
		and not grouped
		and record.group == nil
		and not box.roundedClip
		and not (box.image and box.image.groupClip)
end

function SceneRenderer.apply(
	self: Renderer,
	plan: SceneTypes.Plan,
	snapshot: SceneTypes.Snapshot,
	sourceToken: {}?
): (boolean, string?)
	if self._destroyed then
		return false, "scene-renderer-destroyed"
	end
	if self._committing then
		return false, "reentrant-scene-commit"
	end
	local paintRevision = self._paintRevision
	-- Only a successful commit in the same default-host resource epoch can
	-- retain native work. Custom scenes and failure retries validate/write fully.
	local reusePaint = snapshot.layoutRevision ~= nil and paintRevision == snapshot.layoutRevision
	self._paintRevision = nil
	local boxCache = self._boxCache
	self._boxCache = nil
	local listCache = self._listCache
	self._listCache = nil
	retainInputs(plan, snapshot, self._paintCache, self._glyphCache, boxCache)
	local transforms: { [SceneTypes.Key]: SceneTransforms.Prepared } = {}
	local transformBases: { [SceneTypes.Key]: SceneTransforms.Base } = {}
	local transformNodes: { [Types.Node]: boolean } = {}
	local prepare = Profiler.wrap(self._options.onProfile, "native.prepare", ScenePreparation.prepare)
	local prepared, preparationFailure, nextBoxCache = prepare(
		plan,
		snapshot,
		self._fonts,
		self._options.systemColors,
		function(key, source, config)
			if not config or config.duration + config.delay <= 0 then
				return false
			end
			local record: Record? = self._records[key]
			if not record then
				return false
			end
			if record.node ~= source.node or record.box.kind ~= (source.kind or "box") then
				return false
			end
			local motion = record.opacity
			-- Keep the surface throughout nonmonotonic easing, including a temporary
			-- value of one. Completion schedules one new scene commit for cleanup.
			return if motion
				then motion:active() or (motion:current() or 1) < 1
				else record.opacityValue ~= nil and record.opacityValue < 1
		end,
		self._paintCache,
		self._glyphCache,
		boxCache,
		sourceToken,
		function(key, style, geometry, units, animated)
			local source = plan.boxes[key]
			local before = self._records[key]
			if
				before
				and (before.node ~= source.node or before.box.kind ~= (source.kind or "box") or before.box._destroyed)
			then
				before = nil
			end
			local base, program, why = SceneTransforms.prepare(
				if before then before.transformBase else nil,
				if before then before.transform else nil,
				style,
				geometry,
				units,
				animated
			)
			if not base then
				return nil, why
			end
			transformBases[key] = base
			if program then
				if transformNodes[source.node] then
					return nil, "transform-transition-multiple-fragments-provider-required"
				end
				transformNodes[source.node] = true
				transforms[key] = program
			end
			return SceneTransforms.intervalRequirement(if program then program.interval else nil), nil
		end
	)
	if not prepared then
		return false, preparationFailure
	end
	local reuseLists = boxCache ~= nil
		and nextBoxCache ~= nil
		and boxCache.revision == nextBoxCache.revision
		and boxCache.fonts == nextBoxCache.fonts
		and boxCache.systemColors == nextBoxCache.systemColors
	local nextListCache: { [SceneTypes.Key]: ListRecord }? = if nextBoxCache then {} else nil
	local groups, boundsFailure = Profiler.measure(self._options.onProfile, "native.bounds", function()
		return SceneBounds.resolve(prepared, function(key)
			local previous = self._records[key]
			return if previous then previous.box:getRasterBounds() else nil
		end, function(key, rect)
			local program = transforms[key]
			local interval = program and program.interval
			if not interval then
				return nil, nil
			end
			local box = prepared.boxes[key]
			return TransformValues.bounds(
				interval.from,
				interval.to,
				interval.context,
				rect,
				box.offsetX - (box.source.offsetX or 0),
				box.offsetY - (box.source.offsetY or 0)
			)
		end)
	end)
	if not groups then
		return false, boundsFailure
	end
	for key, program in transforms do
		local box = prepared.boxes[key]
		local group = groups[key]
		local reference = if group then Vector2.new(group.width, group.height) else box.reference
		local position = if group then nil elseif box.layoutCarrier then box.carrierOffset else box.position
		local baseX = if group then -group.x else assert(position).X.Offset + assert(position).X.Scale * reference.X
		local baseY = if group then -group.y else assert(position).Y.Offset + assert(position).Y.Scale * reference.Y
		local why = SceneTransforms.validatePaint(
			program,
			reference,
			baseX,
			baseY,
			box.offsetX - (box.source.offsetX or 0),
			box.offsetY - (box.source.offsetY or 0)
		)
		if why then
			return false, why
		end
	end
	local validated: { [string]: boolean } = {}
	local animatedNodes: { [Types.Node]: boolean } = {}
	for boxKey, box in prepared.boxes do
		WorkQueue.checkpoint()
		local entry = nextBoxCache and assert(nextBoxCache).entries[box.source]
		if reusePaint and retainedView(self._records[boxKey], box, entry and entry.base, groups[boxKey] ~= nil) then
			continue
		end
		if box.animation then
			if animatedNodes[box.source.node] then
				return false, "animation-multiple-fragments-provider-required"
			end
			animatedNodes[box.source.node] = true
		end
		local bounds = groups[boxKey]
		if bounds then
			local nativePaint, failure =
				NativeBox.prepare(box.geometry, box.paint, Vector2.new(bounds.width, bounds.height))
			if not nativePaint then
				return false, failure
			end
			box.nativePaint = nativePaint
		end
		if box.roundedClip or box.opacitySurface or (box.image and box.image.groupClip) then
			local eligible, reason = NativeClip.checkContext(self._mount)
			if not eligible then
				return false, reason
			end
		end
		if box.editor then
			local overlay = box.editor.placeholderOverlay
			if overlay then
				local valid, failure = self._probe:apply(
					"",
					overlay.width,
					overlay.height,
					overlay.glyph,
					Vector2.new(overlay.width, overlay.height),
					nil,
					"center"
				)
				if not valid then
					return false, failure
				end
			end
			local probe = self._editorProbe
			if not probe then
				local target = Instance.new("TextBox")
				target.Name = "EditorCapabilityProbe"
				target.Visible, target.Active, target.Selectable, target.Interactable, target.TextEditable =
					false, false, false, false, false
				target.Parent = self._probeFrame
				probe = NativeEditor.new(target, self._options.onDiagnostic)
				self._editorProbe = probe
			end
			local sample = table.clone(box.editor)
			sample.data = { value = "" }
			local activeProbe = probe
			if not activeProbe then
				return false, "native-editor-probe-unavailable"
			end
			local ok, valid, failure = pcall(activeProbe.apply, activeProbe, sample)
			if not ok then
				return false, `native-editor-preflight:{tostring(valid)}`
			end
			if not valid then
				return false, failure
			end
		end
		for _, run in box.runs do
			local style = run.style
			local key = string.format(
				"%q|%d|%d|%.17g|%q|%q|%q",
				style.font.Family,
				style.font.Weight.Value,
				style.font.Style.Value,
				style.size,
				style.features,
				run.truncate or "none",
				run.verticalAlign or "top"
			)
			if not validated[key] then
				local valid, failure = self._probe:apply("", 0, 0, style, nil, run.truncate, run.verticalAlign)
				if not valid then
					return false, failure
				end
				validated[key] = true
			end
		end
	end
	local records: { [SceneTypes.Key]: Record } = {}
	if self._destroyed then
		return false, "scene-renderer-destroyed"
	end
	local lists: { [SceneTypes.Key]: NativeList.Layout } = {}
	local listMembers: { [SceneTypes.Key]: boolean } = {}
	for _, list in prepared.lists do
		for _, key in list.views do
			listMembers[key] = true
		end
	end
	local created: { Record } = {}
	local createdLists: { NativeList.Layout } = {}
	local installed = false
	WorkQueue.checkpoint()
	self._committing = true
	local function commit(): string?
		for _, program in transforms do
			local command = program.plan
			if command and (command.owner._destroyed or command.owner._generation ~= command.generation) then
				return "superseded-transform-transition-preflight"
			end
		end
		for key, box in prepared.boxes do
			local previous = self._records[key]
			if previous and previous.node == box.source.node and previous.box.kind == box.kind then
				records[key] = previous
			else
				local record: Record = {
					node = box.source.node,
					box = NativeBox.create(
						self._mount,
						box.kind,
						self._options.onDiagnostic,
						self._options.onInvalidated,
						self._options.onProfile
					),
					runs = {},
				}
				records[key] = record
				table.insert(created, record)
			end
		end
		for key, list in prepared.lists do
			local previous = self._lists[key]
			if previous and previous.container == records[key].box.content then
				lists[key] = previous
			else
				local layout = NativeList.create(records[key].box.content)
				lists[key] = layout
				table.insert(createdLists, layout)
			end
			local supported, failure = lists[key]:isSupported(list.plan)
			if not supported then
				return failure or "native-list-controls-unavailable"
			end
		end
		local retiredContents: { [Instance]: boolean } = {}
		for key, previous in self._records do
			if records[key] ~= previous then
				retiredContents[previous.box.content] = true
				if previous.box._overlay then
					retiredContents[previous.box._overlay] = true
				end
				if previous.box._negativeOverlay then
					retiredContents[previous.box._negativeOverlay] = true
				end
			end
		end
		-- Surviving render fragments can have different logical parents. Detach
		-- them before destroying a retired native parent so portals stay alive.
		if next(retiredContents) then
			for _, record in records do
				local root = record.carrier or record.box.frame
				local parent = root.Parent
				if parent and retiredContents[parent] then
					root.Parent = self._mount
				end
			end
		end
		for key, previous in self._lists do
			if lists[key] ~= previous then
				previous:destroy()
			end
		end
		for key, previous in self._records do
			if records[key] ~= previous then
				dispose(previous, self._owners, self._animations)
			end
		end
		self._records, self._lists = records, lists
		table.clear(self._byNode)
		table.clear(self._fragmented)
		local privateStyles = plan.styles
		for _, record in records do
			record.privateStyle = privateStyles ~= nil and privateStyles[record.node] ~= nil
			if self._byNode[record.node] then
				self._fragmented[record.node] = true
			else
				self._byNode[record.node] = record
			end
		end
		installed = true
		for _, key in prepared.order do
			local box = prepared.boxes[key]
			local record = records[key]
			record.transformBase = transformBases[key]
			record.geometry = box.geometry
			record.metrics = box.source.metrics
			local entry = nextBoxCache and assert(nextBoxCache).entries[box.source]
			local preparedBase = entry and entry.base
			local listMember = listMembers[key] == true
			local sameMembership = record.listMember == listMember
			local parent: Instance = self._mount
			if box.source.parent ~= nil then
				local parentBox = records[box.source.parent].box
				parent = if box.source.outOfFlow then parentBox:getOverlay((box.source.paintZIndex or 0) < 0) else parentBox.content
			end
			if
				reusePaint
				and sameMembership
				and retainedView(record, box, preparedBase, groups[key] ~= nil)
				and box.layoutCarrier == (record.carrier ~= nil)
				and (record.carrier or record.box.frame).Parent == parent
			then
				continue
			end
			if not box.animation then
				releaseAnimations(record, self._animations)
			end
			if box.kind == "button" then
				record.box.frame:SetAttribute("CssPointerBlocked", box.pointerBlocked)
			end
			self._owners[record.box.frame] = box.source.owner or record.node
			if box.layoutCarrier or groups[key] then
				local slot = record.carrier or carrier()
				record.carrier = slot
				slot.Parent = parent
				slot.ZIndex = box.source.paintZIndex or box.source.zIndex or 1
				if not box.layoutCarrier and not listMembers[key] then
					slot.Position = box.position
				end
				-- A native list owns its member root's size and placement. A
				-- transformed box can use a different inner reference, so writing
				-- that size onto its carrier would disturb the list's allocation.
				if not listMembers[key] then
					local size, failure = NativeDimensions.pair(box.geometry.width, box.geometry.height, box.reference)
					if not size then
						return failure
					end
					slot.Size = size
				end
				parent = slot
			elseif record.carrier then
				-- Keep the painted view alive before removing its former carrier.
				record.box.frame.Parent = parent
				if record.group then
					record.group:destroy()
					record.group = nil
				end
				record.carrier:Destroy()
				record.carrier = nil
			end
			local groupBounds = groups[key]
			if groupBounds then
				local group = record.group
					or NativeClip.create(parent :: GuiObject, self._options.onDiagnostic, self._options.onInvalidated)
				record.group = group
				group.group.Name = "CssOpacityGroup"
				group.group.Parent = parent
				local base = if box.layoutCarrier then box.carrierOffset else UDim2.fromOffset(0, 0)
				local reference = Vector2.new(box.geometry.width, box.geometry.height)
				local offset, offsetFailure = NativeDimensions.pair(groupBounds.x, groupBounds.y, reference)
				local extent, extentFailure = NativeDimensions.pair(groupBounds.width, groupBounds.height, reference)
				if not offset or not extent then
					return offsetFailure or extentFailure
				end
				group.group.Position = (base :: UDim2) + offset
				group.group.Size = extent
				group.group.ZIndex = box.source.paintZIndex or box.source.zIndex or 1
				local zero = UDim.new()
				local grouped, groupFailure =
					group:apply({ topLeft = zero, topRight = zero, bottomLeft = zero, bottomRight = zero }, false)
				if not grouped then
					return groupFailure
				end
				parent = group.group
			elseif record.group then
				record.box.frame.Parent = parent
				record.group:destroy()
				record.group = nil
			end
			if record.box.frame.Parent ~= parent then
				record.box.frame.Parent = parent
			end
			-- Static paint needs no controller or Destroying connection. A later
			-- fade starts from the previous committed target, including an outgoing
			-- fade whose surface was retained during preparation.
			if record.opacity then
				record.opacity:apply(box.opacity, box.opacityTransition)
			elseif
				box.opacityTransition
				and box.opacityTransition.duration + box.opacityTransition.delay > 0
				and record.opacityValue ~= nil
				and record.opacityValue ~= box.opacity
			then
				beginOpacity(self, key, record, record.opacityValue):apply(box.opacity, box.opacityTransition)
			elseif record.group then
				record.group.group.GroupTransparency = 1 - box.opacity
			end
			record.opacityValue = box.opacity
			local visible = box.kind == "box" or box.visible
			local writePaint = not reusePaint
				or not sameMembership
				or record.paint ~= box.nativePaint
				or record.paintVisible ~= visible
			if writePaint then
				local applied, boxFailure = record.box:applyPrepared(box.nativePaint, visible)
				if not applied then
					return boxFailure or "native-box-commit-failed"
				end
			end
			record.paint, record.paintVisible = box.nativePaint, visible
			if box.editor then
				local edited, editorFailure = record.box:applyEditor(box.editor)
				if not edited then
					return editorFailure or "native-editor-commit-failed"
				end
			end
			local position: UDim2? = nil
			if groupBounds then
				local point, failure = NativeDimensions.pair(
					-groupBounds.x,
					-groupBounds.y,
					Vector2.new(groupBounds.width, groupBounds.height)
				)
				if not point then
					return failure
				end
				position = point
			elseif box.layoutCarrier or not listMembers[key] then
				position = if box.layoutCarrier then box.carrierOffset :: UDim2 else box.position
			end
			if
				position
				and (
					not reusePaint
					or record.position ~= position
					or record.animations ~= nil
					or record.transform ~= nil
				)
			then
				record.box.frame.Position = position
			end
			-- Native lists own member positions. Forget the manual placement so
			-- leaving a list writes it even if it matches a pre-list position.
			record.position = position
			if record.rotation ~= box.rotation or record.animations ~= nil or record.transform ~= nil then
				record.box.frame.Rotation = box.rotation
				record.rotation = box.rotation
			end
			if
				box.scale ~= 1
				or (box.animationModel and box.animationModel.scaleDriven)
				or SceneTransforms.needsScale(if transforms[key] then transforms[key].interval else nil)
			then
				local scale = record.scale or Instance.new("UIScale")
				scale.Name = "CssTransformScale"
				if scale.Scale ~= box.scale then
					scale.Scale = box.scale
				end
				scale.Parent = record.box.frame
				record.scale = scale
			elseif record.scale then
				record.scale:Destroy()
				record.scale = nil
			end
			local rank = box.source.paintZIndex or box.source.zIndex or 1
			if writePaint or record.rank ~= rank then
				-- Paint can create decorative children that need the current rank.
				record.box:setZIndex(rank)
			end
			record.rank = rank
			if box.image then
				local imaged, imageFailure = record.box:applyImage(box.image)
				if not imaged then
					return imageFailure or "native-image-commit-failed"
				end
			end
			-- Empty and single-run boxes need no temporary membership index.
			local runCount = #box.runs
			local onlyKey = if runCount == 1 then box.runs[1].key else nil
			local wanted: { [SceneTypes.RunKey]: boolean }? = nil
			if runCount > 1 then
				wanted = {}
				for _, run in box.runs do
					wanted[run.key] = true
				end
			end
			for runKey, view in record.runs do
				if runKey ~= onlyKey and (not wanted or not wanted[runKey]) then
					self._owners[view.label] = nil
					view:destroy()
					record.runs[runKey] = nil
				end
			end
			for _, run in box.runs do
				local view = record.runs[run.key]
				if not view then
					local createdView = NativeText.create(record.box.content, self._options.onDiagnostic)
					view = createdView
					record.runs[run.key] = view
					if self._options.observeTextBounds ~= false then
						local runKey = run.key
						createdView:subscribeBounds(function()
							if
								not self._destroyed
								and self._records[key] == record
								and record.runs[runKey] == createdView
							then
								self._options.onInvalidated()
							end
						end)
					end
				end
				local appliedRun, runFailure = view:apply(
					run.text,
					run.width,
					run.height,
					run.style,
					Vector2.new(box.geometry.contentWidth, box.geometry.contentHeight),
					run.truncate,
					run.verticalAlign
				)
				if not appliedRun then
					return runFailure or "native-glyph-commit-failed"
				end
				view.label.Position = run.position
				self._owners[view.label] = run.owner
				view.label.ZIndex = run.zIndex
			end
			record.base, record.listMember = preparedBase, listMember
		end
		for key, list in prepared.lists do
			-- Certified formatter inputs can recreate an equivalent list plan.
			-- Paint can still replace a member's native root (for example an
			-- opacity carrier), so compare those roots before retaining layout.
			-- Resource invalidation, custom scenes and failed commits apply fully.
			local previous = if reuseLists and listCache then assert(listCache)[key] else nil
			local unchanged = previous ~= nil and previous.layout == lists[key] and sameListPlan(previous.source, list)
			if unchanged then
				for _, item in list.plan.items do
					local record = records[list.views[item.node]]
					if (record.carrier or record.box.frame) ~= assert(previous).views[item.node] then
						unchanged = false
						break
					end
				end
			end
			if unchanged then
				assert(nextListCache)[key] = assert(previous)
				continue
			end
			local views: { [Types.Node]: GuiObject } = {}
			for _, item in list.plan.items do
				local record = records[list.views[item.node]]
				views[item.node] = record.carrier or record.box.frame
			end
			local applied, listFailure = lists[key]:apply(list.plan, views)
			if not applied then
				return listFailure or "native-list-commit-failed"
			end
			if nextListCache then
				assert(nextListCache)[key] = { source = list, layout = lists[key], views = views }
			end
		end
		for _, key in prepared.order do
			local box = prepared.boxes[key]
			local data = box.animation
			if not data then
				continue
			end
			local record = records[key]
			local controller = record.animations
			if not controller or controller._destroyed then
				controller = NativeAnimations.new(record.box.frame, function()
					if not self._destroyed and self._records[key] == record then
						self._options.onInvalidated()
					end
				end, self._options.onDiagnostic)
				record.animations = controller
				self._animations[record.node] = controller
			end
			local model = box.animationModel
			local basePosition = record.position
			local groupBounds = groups[key]
			local reference = if groupBounds then Vector2.new(groupBounds.width, groupBounds.height) else box.reference
			local baseX, baseY = box.offsetX - (box.source.offsetX or 0), box.offsetY - (box.source.offsetY or 0)
			local stationary = model
				and not data.controlled.translate
				and not model.scaleDriven
				and model.ax == 0
				and model.bx == 0
				and model.ay == 0
				and model.by == 0
				and model.cx == baseX
				and model.cy == baseY
			local lastRotation: number? = nil
			local lastPosition: UDim2? = nil
			local lastOpacity: number? = nil
			local lastScale: number? = nil
			assert(controller):update(data, function(values)
				if self._destroyed or self._records[key] ~= record or record.box._destroyed then
					return
				end
				if model then
					local rotate, transform, translate = values.rotate, values.transform, values.translate
					assert(rotate == nil or type(rotate) == "number", "animation-angle-number-required")
					assert(transform == nil or type(transform) == "number", "animation-angle-number-required")
					assert(translate == nil or type(translate) == "table", "animation-translation-point-required")
					local scaling = values.scale
					assert(scaling == nil or type(scaling) == "number", "animation-scale-number-required")
					local angle = ((rotate or 0) % 360 + (transform or 0) % 360) % 360
					local x, y, rotation, scale = AnimationValues.position(model, angle, translate, scaling)
					if not stationary then
						local offset, why = NativeDimensions.pair(x - baseX, y - baseY, reference)
						assert(offset, why)
						local position = assert(basePosition) + offset
						if position ~= lastPosition then
							record.box.frame.Position = position
							lastPosition = position
						end
					end
					if rotation ~= lastRotation then
						record.box.frame.Rotation = rotation
						lastRotation = rotation
					end
					if model.scaleDriven and scale ~= lastScale then
						assert(record.scale).Scale = scale
						lastScale = scale
					end
				end
				if data.opacityNeeded and record.group then
					local opacity = values.opacity
					assert(opacity == nil or type(opacity) == "number", "animation-opacity-number-required")
					local value = math.clamp(opacity or box.opacity, 0, 1)
					if value ~= lastOpacity then
						record.group.group.GroupTransparency = 1 - value
						lastOpacity = value
					end
				end
			end)
		end
		for _, key in prepared.order do
			local record = records[key]
			local program = transforms[key]
			if not program then
				if record.transform then
					record.transform:destroy()
					record.transform = nil
				end
				record.transformPaint = nil
				continue
			end
			local box = prepared.boxes[key]
			local group = groups[key]
			local reference = if group then Vector2.new(group.width, group.height) else box.reference
			local base = record.position
			local baseX = if base then base.X.Offset + base.X.Scale * reference.X else 0
			local baseY = if base then base.Y.Offset + base.Y.Scale * reference.Y else 0
			local targetX = box.offsetX - (box.source.offsetX or 0)
			local targetY = box.offsetY - (box.source.offsetY or 0)
			local lastPosition: UDim2? = nil
			local lastRotation: number? = nil
			local lastScale: number? = nil
			record.transformPaint = function(value)
				if self._destroyed or self._records[key] ~= record or record.box._destroyed then
					return
				end
				local pose, why = TransformValues.resolve(value, program.context)
				assert(pose, why)
				if base then
					local point, failure =
						NativeDimensions.pair(baseX + pose.x - targetX, baseY + pose.y - targetY, reference)
					assert(point, failure)
					if point ~= lastPosition then
						record.box.frame.Position = point
						lastPosition = point
					end
				end
				local rotation, scale = pose.rotation or 0, pose.scale or 1
				if rotation ~= lastRotation then
					record.box.frame.Rotation = rotation
					lastRotation = rotation
				end
				if record.scale and scale ~= lastScale then
					record.scale.Scale = scale
					lastScale = scale
				end
			end
			local motion = record.transform
			if not motion then
				motion = beginTransform(self, key, record)
				motion:apply(assert(program.seed), nil)
				motion:apply(program.target, program.config)
			else
				assert(motion:commit(assert(program.plan)), "superseded-transform-transition-preflight")
			end
			local owner = assert(motion)
			if not owner:active() then
				owner:destroy()
				record.transform, record.transformPaint = nil, nil
			end
		end
		return nil
	end
	local ok, failure = pcall(WorkQueue.atomic, Profiler.wrap(self._options.onProfile, "native.write", commit))
	self._committing = false
	if not installed then
		for _, list in createdLists do
			list:destroy()
		end
		for _, record in created do
			dispose(record, self._owners, self._animations)
		end
	end
	if not ok then
		return false, `native-scene-commit:{tostring(failure)}`
	end
	if failure == nil and not self._destroyed then
		-- The formatter/cache share this map. Retired generated fragments must
		-- not retain their logical parent through a stale transient context.
		local requirements = snapshot.transformTransitions
		if requirements then
			for node in requirements do
				if not self._byNode[node] then
					requirements[node] = nil
				end
			end
		end
		self._paintRevision = snapshot.layoutRevision
		self._boxCache = nextBoxCache
		self._listCache = nextListCache
	end
	return failure == nil, failure
end

function SceneRenderer.destroy(self: Renderer)
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self._ancestryConnection then
		self._ancestryConnection:Disconnect()
		self._ancestryConnection = nil
	end
	if self._contextConnection then
		self._contextConnection:Disconnect()
		self._contextConnection = nil
	end
	self._contextSurface = nil
	self._paintRevision = nil
	for _, list in self._lists do
		list:destroy()
	end
	for _, record in self._records do
		dispose(record, self._owners, self._animations)
	end
	table.clear(self._lists)
	table.clear(self._records)
	table.clear(self._byNode)
	table.clear(self._fragmented)
	table.clear(self._paintCache)
	table.clear(self._glyphCache)
	self._boxCache = nil
	self._listCache = nil
	table.clear(self._owners)
	table.clear(self._animations)
	self._probe:destroy()
	if self._editorProbe then
		self._editorProbe:destroy()
		self._editorProbe = nil
	end
	self._probeFrame:Destroy()
end

export type Renderer = typeof(setmetatable(
	{} :: {
		_mount: Frame,
		_fonts: Fonts.Provider,
		_options: Options,
		_probeFrame: Frame,
		_probe: NativeText.View,
		_editorProbe: NativeEditor.View?,
		_records: { [SceneTypes.Key]: Record },
		_byNode: { [Types.Node]: Record },
		_fragmented: { [Types.Node]: boolean },
		_paintCache: ScenePreparation.PaintCache,
		_glyphCache: ScenePreparation.GlyphCache,
		_boxCache: ScenePreparation.BoxCache?,
		_listCache: { [SceneTypes.Key]: ListRecord }?,
		_owners: { [Instance]: Types.Node },
		_animations: { [Types.Node]: NativeAnimations.Controller },
		_lists: { [SceneTypes.Key]: NativeList.Layout },
		_destroyed: boolean,
		_committing: boolean,
		_paintRevision: number?,
		_contextSurface: LayerCollector?,
		_contextConnection: RBXScriptConnection?,
		_ancestryConnection: RBXScriptConnection?,
	},
	SceneRenderer
))

return { create = SceneRenderer.new }
