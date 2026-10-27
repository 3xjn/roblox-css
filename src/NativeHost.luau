--!strict

local Types = require(script.Parent.Types)
local StyleRoot = require(script.Parent.StyleRoot)
local Conditions = require(script.Parent.Conditions)
local Fonts = require(script.Parent.Fonts)
local SceneTypes = require(script.Parent.SceneTypes)
local AnimationTracks = require(script.Parent.AnimationTracks)
local Easing = require(script.Parent.Easing)
local SceneAnimations = require(script.Parent.SceneAnimations)
local Playback = require(script.Parent.Playback)
local SceneRenderer = require(script.Parent.SceneRenderer)
local BlockScene = require(script.Parent.BlockScene)
local TextMeasurement = require(script.Parent.TextMeasurement)
local NativeTextMeasurement = require(script.Parent.NativeTextMeasurement)
local TextLine = require(script.Parent.TextLine)
local SceneCache = require(script.Parent.SceneCache)
local Profiler = require(script.Parent.Profiler)
local WorkQueue = require(script.Parent.WorkQueue)
local BoxModel = require(script.Parent.BoxModel)
local InlineStyle = require(script.Parent.InlineStyle)

export type ImageProviderInputs = { attributes: { string }, states: { string } }

export type Options = {
	onProfile: Profiler.Sink?,
	-- Cooperative preparation budget. Omission/zero keeps ordinary scheduling.
	workBudgetMs: number?,
	scene: SceneTypes.Provider?,
	styles: StyleRoot.RootOptions?,
	systemColors: { [string]: Types.RgbaColor }?,
	textMeasurements: TextMeasurement.Options?,
	textGeometry: TextLine.GeometryProvider?,
	nativeTextLine: boolean?,
	flexIntrinsic: BlockScene.FlexIntrinsicProvider?,
	editorBaselines: BlockScene.EditorBaselineProvider?,
	imageSource: BlockScene.ImageProvider?,
	imageContentSource: BlockScene.ImageProvider?,
	-- Exact logical inputs read by a custom image provider. Omission keeps
	-- conservative attribute/state invalidation; external resources explicitly
	-- invalidate the scene independently of these node inputs.
	imageSourceInputs: ImageProviderInputs?,
	imageContentSourceInputs: ImageProviderInputs?,
	-- Default: an unscaled mount's AbsoluteSize. A scaled surface supplies its
	-- own logical-pixel conversion; the host never guesses ancestor UIScales.
	getViewport: ((Frame) -> Vector2)?,
}

local NativeHost = {}
NativeHost.__index = NativeHost

local function sceneInputs(options: Options): SceneCache.Inputs?
	if options.flexIntrinsic or options.editorBaselines then
		return nil
	end
	local result: SceneCache.Inputs = {
		attributes = { type = true, src = true, value = true, ["default-value"] = true, placeholder = true },
		states = {},
	}
	local function include(provider: BlockScene.ImageProvider?, inputs: ImageProviderInputs?): boolean
		if not provider then
			return true
		end
		if not inputs then
			return false
		end
		for _, name in inputs.attributes do
			assert(type(name) == "string" and name ~= "", "Image attribute inputs require names")
			result.attributes[name] = true
		end
		for _, name in inputs.states do
			assert(type(name) == "string" and name ~= "", "Image state inputs require names")
			result.states[name] = true
		end
		return true
	end
	if
		not include(options.imageSource, options.imageSourceInputs)
		or not include(options.imageContentSource, options.imageContentSourceInputs)
	then
		return nil
	end
	return result
end

local function environment(source: Conditions.Environment?): Conditions.Environment
	local defaults: Conditions.Environment = source or {}
	local result = table.clone(defaults)
	if result.features then
		result.features = table.clone(result.features)
	end
	return result
end

function NativeHost.new(parent: GuiObject, stylesheet: Types.Stylesheet, options: Options): Host
	local budget = options.workBudgetMs or 0
	assert(budget >= 0 and budget < math.huge, "Work budget must be finite and nonnegative")
	local workQueue = if budget > 0 then WorkQueue.create(budget) else nil
	local defaults: StyleRoot.RootOptions = options.styles or {}
	local settings = table.clone(defaults)
	settings.onProfile = options.onProfile or settings.onProfile
	local fonts = settings.fonts or Fonts.create()
	settings.fonts = fonts
	local metricsProvider = settings.fontMetrics or function(style)
		return fonts:getMetrics(style)
	end
	local scene = options.scene
	-- Built-in formatting uses requested text geometry, not last-commit ink.
	-- Custom scenes and intrinsic providers receive the snapshot and may read it.
	local captureMeasurements = scene ~= nil or options.flexIntrinsic ~= nil
	local clearSceneCache: (() -> ())? = nil
	local scenePresentation: (() -> ({}?, {}?))? = nil
	if not scene then
		local inputs = sceneInputs(options)
		local fixedMetrics = inputs ~= nil and defaults.fontMetrics == nil and options.textGeometry == nil
		local formatter = BlockScene.create({
			fonts = fonts,
			fontMetrics = metricsProvider,
			textGeometry = options.textGeometry,
			nativeTextLine = options.nativeTextLine,
			flexIntrinsic = options.flexIntrinsic,
			editorBaselines = options.editorBaselines,
			imageSource = options.imageSource,
			imageContentSource = options.imageContentSource,
			intrinsicInputs = if fixedMetrics then inputs else nil,
			immutableFragments = fixedMetrics,
		})
		if fixedMetrics then
			local cached, clear, presentation = SceneCache.create(formatter, inputs)
			clearSceneCache, scenePresentation = clear, presentation
			scene = function(snapshot)
				if Fonts.hasDefaultMetrics(fonts) then
					return cached(snapshot)
				end
				-- Matching methods can be overridden after host creation. Drop
				-- both scene tokens and intrinsic proofs on the next evaluation.
				clear()
				return formatter(snapshot)
			end
		else
			-- Unknown readers own their sizing dependencies and mutable inputs.
			scene = formatter
		end
	end
	local styles = StyleRoot.createRoot(stylesheet, settings, workQueue)
	local mount = Instance.new("Frame")
	mount.Name = "CssHost"
	mount.AnchorPoint = Vector2.zero
	mount.Position = UDim2.fromOffset(0, 0)
	mount.Size = UDim2.fromScale(1, 1)
	mount.AutomaticSize = Enum.AutomaticSize.None
	mount.BackgroundTransparency = 1
	mount.BorderSizePixel = 0
	mount.ClipsDescendants = false
	mount.Active = false
	mount.Selectable = false
	local backend = if not options.textMeasurements or not options.textMeasurements.measureAsync
		then NativeTextMeasurement.create(mount)
		else nil
	local created, measurements = pcall(TextMeasurement.create, options.textMeasurements, backend)
	if not created then
		styles:destroy()
		if backend then
			backend.destroy()
		end
		mount:Destroy()
		error(measurements, 2)
	end
	local textMeasurements = measurements :: TextMeasurement.Cache
	local self = setmetatable({
		mount = mount,
		_styles = styles,
		_options = options,
		_scene = Profiler.wrap(options.onProfile, "layout", assert(scene)),
		_clearSceneCache = clearSceneCache,
		_scenePresentation = scenePresentation,
		_committedPresentation = nil :: {}?,
		_captureMeasurements = captureMeasurements,
		_textMeasurements = textMeasurements,
		_readText = function(text: string, shape: TextMeasurement.Shape)
			return textMeasurements:get(text, shape)
		end,
		_anonymousStyle = function(parent: Types.Node)
			return styles:getAnonymousStyle(parent)
		end,
		_pseudoStyle = function(node: Types.Node, name: string)
			return styles:getComputedPseudoStyle(node, name)
		end,
		_renderer = nil :: SceneRenderer.Renderer?,
		_environment = environment(settings.environment),
		_viewport = Vector2.zero,
		_nodes = {} :: { [Types.Node]: boolean },
		_roots = {} :: { Types.Node },
		_connections = {} :: { RBXScriptConnection },
		_subscriptions = {} :: { () -> () },
		_listeners = {} :: { [(number) -> ()]: boolean },
		_destroyed = false,
		_pending = false,
		_workQueue = workQueue,
		_flushing = false,
		_dirty = false,
		_sceneRevision = 0,
		_committedSceneRevision = nil :: number?,
		_layoutRevision = 0,
		_lastFailure = nil :: string?,
	}, NativeHost)
	self._renderer = SceneRenderer.create(mount, fonts, {
		onProfile = options.onProfile,
		observeTextBounds = captureMeasurements,
		systemColors = options.systemColors,
		onDiagnostic = function(failure)
			self:_report(failure)
		end,
		onInvalidated = function()
			self:invalidateScene()
		end,
		onPaintInvalidated = function()
			-- Native resource settlement needs a commit, but changes no CSS
			-- measurement input. Keep formatting caches; bypass only paint reuse.
			self._committedPresentation = nil
			self:invalidateScene(false)
		end,
	})
	table.insert(
		self._subscriptions,
		styles:subscribeCommit(function()
			self:invalidateScene(false)
		end)
	)
	table.insert(
		self._subscriptions,
		textMeasurements:subscribe(function()
			self:invalidateScene()
		end)
	)
	table.insert(
		self._subscriptions,
		fonts:subscribe(function()
			textMeasurements:clear()
		end)
	)
	table.insert(
		self._connections,
		mount.Destroying:Connect(function()
			self:_release(false)
		end)
	)
	table.insert(
		self._connections,
		mount:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if self._destroyed then
				return
			end
			local ok, failure = pcall(function()
				self:refreshViewport()
			end)
			if not ok then
				self:_report(`viewport:{tostring(failure)}`)
			end
		end)
	)
	local ok, failure = pcall(function()
		mount.Parent = parent
		self:refreshViewport(true)
	end)
	if not ok then
		self:destroy()
		error(`Unable to initialize CSS host viewport: {tostring(failure)}`, 2)
	end
	return self
end

function NativeHost._report(self: Host, failure: string)
	if self._destroyed or self._lastFailure == failure then
		return
	end
	self._lastFailure = failure
	local callback = if self._options.styles then self._options.styles.onDiagnostic else nil
	if callback then
		callback("native-host", failure, nil)
	else
		warn(`[roblox-css:native-host] {failure}`)
	end
end

function NativeHost.refreshViewport(self: Host, force: boolean?)
	assert(not self._destroyed, "CSS host has been destroyed")
	local size = if self._options.getViewport then self._options.getViewport(self.mount) else self.mount.AbsoluteSize
	assert(
		size.X >= 0 and size.Y >= 0 and size.X < math.huge and size.Y < math.huge,
		"A finite logical viewport is required"
	)
	if not force and self._viewport == size then
		return
	end
	self._viewport = size
	self._environment.viewportWidth, self._environment.viewportHeight = size.X, size.Y
	self._styles:setEnvironment(self._environment)
end

function NativeHost.setEnvironment(self: Host, value: Conditions.Environment)
	assert(not self._destroyed, "CSS host has been destroyed")
	self._environment = environment(value)
	self:refreshViewport(true)
end

function NativeHost.invalidateScene(self: Host, layoutChanged: boolean?)
	if self._destroyed then
		return
	end
	self._sceneRevision += 1
	if layoutChanged ~= false then
		self._layoutRevision += 1
	end
	if self._flushing then
		self._dirty = true
		return
	end
	if self._pending then
		return
	end
	self._pending = true
	local update = function()
		self._pending = false
		if not self._destroyed then
			self:_flush()
		end
	end
	if self._workQueue then
		self._workQueue:defer(update)
	else
		task.defer(update)
	end
end

function NativeHost._flush(self: Host)
	if self._flushing then
		self._dirty = true
		return
	end
	local revision, committed = self._styles:getRevision()
	if revision ~= committed then
		return
	end -- The next stable style commit wakes the host.
	if self._committedSceneRevision == self._sceneRevision and self._lastFailure == nil then return end
	local renderer = self._renderer
	if not renderer then
		return
	end
	local sceneRevision = self._sceneRevision
	local waitingForText = false
	self._flushing = true
	local ok, failure = pcall(Profiler.wrap(self._options.onProfile, "host.flush", function(): string?
		return WorkQueue.guard(function()
			return not self._destroyed
				and self._styles:getRevision() == revision
				and self._sceneRevision == sceneRevision
		end, function(): string?
			self._textMeasurements:beginPass()
			local snapshot: SceneTypes.Snapshot = {
				revision = revision,
				layoutRevision = self._layoutRevision,
				roots = table.clone(self._roots),
				styles = {},
				viewport = self._viewport,
				initialFontSize = self._environment.initialFontSize,
				measureText = self._readText,
				anonymousStyle = self._anonymousStyle,
				pseudoStyle = self._pseudoStyle,
				measurements = if self._captureMeasurements then renderer:measurements() else {},
			}
			for node in self._nodes do
				local style = self._styles:getComputedStyle(node)
				if not style then
					return "scene-style-not-computed"
				end
				snapshot.styles[node] = style
			end
			local animations: { [Types.Node]: SceneAnimations.Data } = {}
			snapshot.animations = animations
			local function resolveAnimation(
				node: Types.Node,
				style: Types.ComputedStyle,
				origin: Types.Node?,
				pseudo: string?
			): (SceneAnimations.Data?, string?)
				local data, why = SceneAnimations.resolve(style, function(name, easing)
					return self._styles:getAnimationTracks(origin or node, name, easing, pseudo)
				end, function(effects)
					return renderer:animationTimes(node, effects)
				end)
				if why then
					return nil, why
				end
				animations[node] = data
				return data, nil
			end
			snapshot.animation = resolveAnimation
			for node, style in snapshot.styles do
				if SceneAnimations.has(style) then
					local _, why = resolveAnimation(node, style)
					if why then
						return why
					end
				end
			end
			local transforms, transformFailure = renderer:transformRequirements(snapshot.styles)
			if transformFailure then
				return transformFailure
			end
			snapshot.transformTransitions = transforms
			snapshot.transformTransition = function(node, style)
				return renderer:transformRequirement(node, style)
			end
			local plan, reason = self._scene(snapshot)
			if self._destroyed then
				return nil
			end
			if self._styles:getRevision() ~= revision or self._sceneRevision ~= sceneRevision then
				return nil
			end
			if not plan then
				if reason == "pending-text-measurement" then
					waitingForText = true
					return nil -- The cache completion event wakes the host.
				end
				return reason or "scene-provider-returned-no-plan"
			end
			local presentation: {}? = nil
			local geometry: {}? = nil
			if self._scenePresentation then
				presentation, geometry = self._scenePresentation()
			end
			-- The formatter cache certifies unchanged geometry, provider inputs and
			-- ordinary/private styles. Compare with the last successful native commit,
			-- never a merely prepared or aborted scene. Resolved animation program or
			-- lifecycle changes and explicit invalidation produce a new token; unchanged
			-- animations keep their existing native clocks and paint callbacks.
			if presentation == nil or presentation ~= self._committedPresentation or self._lastFailure ~= nil then
				local applied, renderFailure =
					renderer:apply(plan, snapshot, if self._lastFailure == nil then geometry else nil)
				if not applied then
					return renderFailure or "native-scene-failed"
				end
				if self._destroyed then
					return nil
				end
				self._committedPresentation = presentation
			end
			self._lastFailure = nil
			self._committedSceneRevision = sceneRevision
			if self._styles:getRevision() == revision then
				for listener in table.clone(self._listeners) do
					if self._destroyed or self._styles:getRevision() ~= revision then
						break
					end
					if self._listeners[listener] then
						listener(revision)
					end
				end
			end
			return nil
		end)
	end))
	self._textMeasurements:endPass(
		waitingForText
			and not self._destroyed
			and self._sceneRevision == sceneRevision
			and self._styles:getRevision() == revision
	)
	self._flushing = false
	if self._dirty and not self._destroyed then
		self._dirty = false
		self:invalidateScene()
	end
	if not ok and WorkQueue.isCancelled(failure) then
		return
	elseif not ok then
		self:_report(`scene-provider:{tostring(failure)}`)
	elseif failure then
		self:_report(failure)
	end
end

function NativeHost.add(self: Host, options: StyleRoot.NodeOptions?, parent: Types.Node?): Types.Node
	assert(not self._destroyed, "CSS host has been destroyed")
	local node = self._styles:add(options, parent)
	self._nodes[node] = true
	if not parent then
		table.insert(self._roots, node)
	end
	return node
end

function NativeHost.update(self: Host, node: Types.Node, options: StyleRoot.NodeOptions)
	assert(not self._destroyed, "CSS host has been destroyed")
	self._styles:update(node, options)
end

-- The actual declaration IR is copied at this explicit native boundary.
function NativeHost.getInlineStyle(self: Host, node: Types.Node): Types.InlineStyle
	assert(not self._destroyed and self._nodes[node], "CSS target is detached")
	return InlineStyle.copy(node.inlineStyle) or { declarations = {} }
end
function NativeHost.setInlineStyle(self: Host, node: Types.Node, style: Types.InlineStyle)
	assert(not self._destroyed and self._nodes[node], "CSS target is detached")
	self._styles:update(node, { inlineStyle = style })
end
function NativeHost.getInlineProperty(self: Host, node: Types.Node, name: string): (string, string)
	assert(not self._destroyed and self._nodes[node], "CSS target is detached")
	return InlineStyle.getProperty(node.inlineStyle, name)
end
function NativeHost.setInlineProperty(self: Host, node: Types.Node, name: string, value: string, priority: string?)
	assert(not self._destroyed and self._nodes[node], "CSS target is detached")
	local style, failure = InlineStyle.setProperty(node.inlineStyle, name, value, priority)
	assert(style, failure)
	self._styles:update(node, { inlineStyle = style })
end
-- One attempt through the existing cascade/scene/renderer pipeline. Async text
-- cache misses and reentrant/busy work cannot be disguised as a fresh layout.
function NativeHost.flushSync(self: Host): (boolean, string?)
	if self._destroyed then return false, "css-host-destroyed" end
	-- DOM geometry and computed-style reads are often clustered within one
	-- event. A fully committed host needs no synchronous work for later reads.
	if not self._flushing and self._lastFailure == nil then
		local revision, committed = self._styles:getRevision()
		if revision == committed and self._committedSceneRevision == self._sceneRevision then
			return true, nil
		end
	end
	if self._flushing and self._workQueue then
		self._textMeasurements:setSynchronous(true)
		local ok, failure = pcall(function() self._workQueue:flushSync() end)
		self._textMeasurements:setSynchronous(false)
		if not ok then return false, "synchronous-scene-failure:" .. tostring(failure) end
	end
	if self._flushing then return false, "native-scene-update-in-progress" end
	local styled, reason = self._styles:flushSync()
	if not styled then return false, reason end
	self._textMeasurements:setSynchronous(true)
	local ok, failure = pcall(function() WorkQueue.atomic(function() self:_flush() end) end)
	self._textMeasurements:setSynchronous(false)
	if not ok then return false, "synchronous-scene-failure:" .. tostring(failure) end
	local revision, committed = self._styles:getRevision()
	if self._destroyed then return false, "css-host-destroyed" end
	if revision ~= committed or self._committedSceneRevision ~= self._sceneRevision then
		return false, self._lastFailure or "native-layout-not-synchronously-committed"
	end
	if self._lastFailure then return false, self._lastFailure end
	return true, nil
end

function NativeHost.setId(self: Host, node: Types.Node, id: string?)
	assert(not self._destroyed, "CSS host has been destroyed")
	self._styles:setId(node, id)
end

function NativeHost.setState(self: Host, node: Types.Node, name: string, active: boolean)
	assert(not self._destroyed, "CSS host has been destroyed")
	self._styles:setState(node, name, active)
end

function NativeHost.setAttribute(self: Host, node: Types.Node, name: string, value: string?)
	assert(not self._destroyed, "CSS host has been destroyed")
	self._styles:setAttribute(node, name, value)
end

function NativeHost.reparent(self: Host, node: Types.Node, parent: Types.Node?)
	assert(not self._destroyed, "CSS host has been destroyed")
	self._styles:reparent(node, parent)
	local index = table.find(self._roots, node)
	if index then
		table.remove(self._roots, index)
	end
	if not parent then
		table.insert(self._roots, node)
	end
end

function NativeHost.remove(self: Host, node: Types.Node)
	if self._destroyed or not self._nodes[node] then
		return
	end
	local function discard(target: Types.Node)
		self._nodes[target] = nil
		for _, child in target.children do
			discard(child)
		end
	end
	discard(node)
	local index = table.find(self._roots, node)
	if index then
		table.remove(self._roots, index)
	end
	self._styles:remove(node)
end

function NativeHost.reorder(self: Host, parent: Types.Node?, children: { Types.Node })
	assert(not self._destroyed, "CSS host has been destroyed")
	self._styles:reorder(parent, children)
	if not parent then
		self._roots = table.clone(children)
	end
end

function NativeHost.contains(self: Host, node: Types.Node): boolean
	return not self._destroyed and self._nodes[node] == true
end

function NativeHost.invalidateTextMeasurements(self: Host)
	if self._destroyed then
		return
	end
	self._textMeasurements:clear()
	self:invalidateScene()
end

function NativeHost.getComputedStyle(self: Host, node: Types.Node): Types.ComputedStyle?
	return if self._nodes[node] then self._styles:getComputedStyle(node) else nil
end

function NativeHost.getResolvedProperty(self: Host, key: SceneTypes.Key, name: string): (string?, string?)
	if self._destroyed then
		return nil, "css-host-destroyed"
	end
	local revision, committed = self._styles:getRevision()
	if revision ~= committed or self._committedSceneRevision ~= self._sceneRevision or self._lastFailure then
		return nil, self._lastFailure or "resolved-style-scene-not-committed"
	end
	return assert(self._renderer):getResolvedProperty(key, name)
end

function NativeHost.getKeyframes(self: Host, node: Types.Node, name: string): (Types.PreparedKeyframes?, string?)
	return self._styles:getKeyframes(node, name)
end

function NativeHost.getAnimationTracks(
	self: Host,
	node: Types.Node,
	name: string,
	easing: Easing.Curve
): (AnimationTracks.Result?, string?)
	return self._styles:getAnimationTracks(node, name, easing)
end

function NativeHost.getComputedPseudoStyle(self: Host, node: Types.Node, name: string): Types.ComputedStyle?
	return if self._nodes[node] then self._styles:getComputedPseudoStyle(node, name) else nil
end

function NativeHost.getGuiObject(self: Host, key: SceneTypes.Key): GuiObject?
	return if self._renderer then self._renderer:getGuiObject(key) else nil
end

function NativeHost.getImageLabel(self: Host, key: SceneTypes.Key): ImageLabel?
	return if self._renderer then self._renderer:getImageLabel(key) else nil
end

-- Committed, untransformed CSS dimensions, independent of native encoding and
-- ancestor UIScales. Callers own this snapshot; they cannot mutate the scene.
function NativeHost.getLayoutBox(self: Host, key: SceneTypes.Key): BoxModel.Geometry?
	return if self._renderer then self._renderer:getLayoutBox(key) else nil
end

function NativeHost.getPlaybacks(self: Host, key: SceneTypes.Key, subtree: boolean?): { Playback.Handle }
	return if self._renderer and not self._destroyed then self._renderer:getPlaybacks(key, subtree) else {}
end

function NativeHost.getOwner(self: Host, target: Instance): Types.Node?
	local owner = if self._renderer then self._renderer:getOwner(target) else nil
	return if owner and self._nodes[owner] then owner else nil
end

function NativeHost.subscribeScene(self: Host, listener: (number) -> ()): () -> ()
	assert(not self._destroyed, "CSS host has been destroyed")
	self._listeners[listener] = true
	return function()
		self._listeners[listener] = nil
	end
end

function NativeHost._release(self: Host, destroyMount: boolean)
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self._workQueue then
		self._workQueue:destroy()
		self._workQueue = nil
	end
	-- Release the formatter's retained measurements even when the consumer keeps
	-- a reference to a destroyed host. Pending commits already check _destroyed.
	self._scene = function()
		return nil, "css-host-destroyed"
	end
	if self._clearSceneCache then
		self._clearSceneCache()
		self._clearSceneCache = nil
	end
	self._scenePresentation = nil
	self._committedPresentation = nil
	for _, disconnect in self._subscriptions do
		disconnect()
	end
	table.clear(self._subscriptions)
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._styles:destroy()
	self._textMeasurements:destroy()
	if self._renderer then
		self._renderer:destroy()
		self._renderer = nil
	end
	table.clear(self._nodes)
	table.clear(self._roots)
	table.clear(self._listeners)
	if destroyMount then
		self.mount:Destroy()
	end
end

function NativeHost.destroy(self: Host)
	self:_release(true)
end

export type Host = typeof(setmetatable(
	{} :: {
		mount: Frame,
		_styles: StyleRoot.Root,
		_options: Options,
		_scene: SceneTypes.Provider,
		_clearSceneCache: (() -> ())?,
		_scenePresentation: (() -> ({}?, {}?))?,
		_committedPresentation: {}?,
		_captureMeasurements: boolean,
		_textMeasurements: TextMeasurement.Cache,
		_readText: TextMeasurement.Reader,
		_anonymousStyle: (Types.Node) -> (Types.ComputedStyle?, string?),
		_pseudoStyle: (Types.Node, string) -> Types.ComputedStyle?,
		_renderer: SceneRenderer.Renderer?,
		_environment: Conditions.Environment,
		_viewport: Vector2,
		_nodes: { [Types.Node]: boolean },
		_roots: { Types.Node },
		_connections: { RBXScriptConnection },
		_subscriptions: { () -> () },
		_listeners: { [(number) -> ()]: boolean },
		_destroyed: boolean,
		_pending: boolean,
		_workQueue: WorkQueue.Queue?,
		_flushing: boolean,
		_dirty: boolean,
		_sceneRevision: number,
		_committedSceneRevision: number?,
		_layoutRevision: number,
		_lastFailure: string?,
	},
	NativeHost
))

return { create = NativeHost.new }
