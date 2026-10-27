--!strict

local ShadowPaint = require(script.Parent.ShadowPaint)
local ShadowInterpolation = require(script.Parent.ShadowInterpolation)
local Transitions = require(script.Parent.Transitions)
local Playback = require(script.Parent.Playback)

export type Corners = { topLeft: number, topRight: number, bottomLeft: number, bottomRight: number }
export type Spec = { layers: { ShadowPaint.Shadow }, border: number, corners: Corners? }

-- Plans belong to the renderer. A CSS transition has no texture size, raster
-- budget, EditableImage or engine feature-gate dependency.
export type Backend<Plan> = {
	key: (Plan) -> string,
	prepareTransition: (Spec, Spec, number, number) -> (Plan?, string?),
	prepareFrame: (Spec, Plan, number, number) -> (Plan?, string?),
	write: (Spec, Plan, number, number, boolean) -> (boolean, string?),
	releaseTransient: (boolean) -> (),
}
export type Running<Plan> = {
	discrete: boolean,
	from: Spec,
	to: Spec,
	endValue: Spec,
	reverse: Spec,
	factor: number,
	started: number,
	duration: number,
	delay: number,
	easing: Transitions.Easing,
	envelope: Plan,
	width: number,
	height: number,
}
export type State<Plan> = {
	parent: Instance,
	backend: Backend<Plan>,
	current: Spec?,
	target: Spec?,
	targetKey: string?,
	width: number?,
	height: number?,
	running: Running<Plan>?,
	playback: Playback.Controller?,
	driver: NumberValue?,
	tween: Tween?,
	changed: RBXScriptConnection?,
	completed: RBXScriptConnection?,
	onDiagnostic: ((string) -> ())?,
	destroyed: boolean,
}
local ShadowTransition = {}

local function stop<Plan>(view: State<Plan>)
	if view.playback then
		view.playback.cancel()
		view.playback = nil
	end
	if view.changed then
		view.changed:Disconnect()
		view.changed = nil
	end
	if view.completed then
		view.completed:Disconnect()
		view.completed = nil
	end
	if view.tween then
		view.tween:Cancel()
		view.tween:Destroy()
		view.tween = nil
	end
	if view.driver then
		view.driver:Destroy()
		view.driver = nil
	end
	view.running = nil
end

function ShadowTransition.playback<Plan>(view: State<Plan>): Playback.Handle?
	local run = view.running
	if not run or view.destroyed then
		return nil
	end
	local observation: Playback.Controller = view.playback
		or Playback.create({ duration = run.duration, delay = run.delay, iterations = 1 })
	view.playback = observation
	return observation.handle
end

local function sample<Plan>(run: Running<Plan>, now: number): (Spec, number)
	local progress = if now < run.started
		then 0
		elseif run.duration == 0 then 1
		else math.clamp((now - run.started) / run.duration, 0, 1)
	local eased = if now < run.started then 0 else Transitions.ease(run.easing, progress)
	return {
		border = run.to.border,
		corners = run.to.corners,
		layers = if run.discrete
			then (if eased < 0.5 then run.from.layers else run.to.layers)
			else ShadowInterpolation.sample(run.from.layers, run.to.layers, eased),
	},
		eased
end

local function sameGeometry(a: Spec, b: Spec): boolean
	if a.border ~= b.border then
		return false
	end
	local ac, bc = a.corners, b.corners
	if not ac or not bc then
		return ac == bc
	end
	return ac.topLeft == bc.topLeft
		and ac.topRight == bc.topRight
		and ac.bottomLeft == bc.bottomLeft
		and ac.bottomRight == bc.bottomRight
end

function ShadowTransition.apply<Plan>(
	view: State<Plan>,
	spec: Spec,
	prepared: Plan,
	width: number,
	height: number,
	config: Transitions.Config?
): (boolean, string?)
	if view.destroyed then
		return false, "shadow-view-destroyed"
	end
	local backend = view.backend
	local key = backend.key(prepared)
	if view.targetKey == key and (not view.running or config ~= nil) then
		return true, nil
	end
	local now = os.clock()
	local oldRun = view.running
	local before = view.current
	local progress = 0
	if oldRun then
		before, progress = sample(oldRun, now)
	end
	local sameSize = view.width == width and view.height == height
	local target = view.target
	local function adopt()
		view.targetKey = key
		view.target = spec
		view.width = width
		view.height = height
	end
	local function settle(): (boolean, string?)
		stop(view)
		backend.releaseTransient(false)
		local ok, failure = backend.write(spec, prepared, width, height, true)
		if ok then
			backend.releaseTransient(true)
			view.current = spec
			adopt()
		end
		return ok, failure
	end
	if
		not config
		or not before
		or not sameSize
		or not sameGeometry(before, spec)
		or config.duration + config.delay <= 0
	then
		return settle()
	end
	if target and ShadowInterpolation.equal(target.layers, spec.layers) and oldRun then
		return true, nil
	end
	local source: Spec = assert(before)
	local left, right = ShadowInterpolation.pair(source.layers, spec.layers)
	if ShadowInterpolation.equal(source.layers, spec.layers) then
		return settle()
	end
	local discrete = false
	if not left or not right then
		if not config.allowDiscrete then
			return settle()
		end
		left, right = source.layers, spec.layers
		discrete = true
	end
	local fromLayers, toLayers = assert(left), assert(right)
	local factor = 1
	local reverse: Spec = source
	if
		oldRun
		and sameGeometry(oldRun.reverse, spec)
		and ShadowInterpolation.equal(oldRun.reverse.layers, spec.layers)
	then
		factor = math.clamp(math.abs(progress * oldRun.factor + 1 - oldRun.factor), 0, 1)
		reverse = oldRun.endValue
	end
	local duration = config.duration * factor
	local delay = if config.delay < 0 then config.delay * factor else config.delay
	if duration + delay <= 0 then
		return settle()
	end
	local from: Spec = { layers = fromLayers, border = spec.border, corners = spec.corners }
	local to: Spec = { layers = toLayers, border = spec.border, corners = spec.corners }
	local bounds, failure = backend.prepareTransition(from, to, width, height)
	if not bounds then
		-- A failed replacement leaves the previous animation and paint owned.
		return false, failure
	end
	stop(view)
	local run: Running<Plan> = {
		discrete = discrete,
		from = from,
		to = to,
		endValue = spec,
		reverse = reverse,
		factor = factor,
		started = now + delay,
		duration = duration,
		delay = delay,
		easing = config.easing,
		envelope = bounds,
		width = width,
		height = height,
	}
	view.running = run
	local function draw(at: number): (boolean, string?)
		local value = sample(run, at)
		view.current = value
		local frame, reason = backend.prepareFrame(value, bounds, width, height)
		if not frame then
			return false, reason
		end
		return backend.write(value, frame, width, height, false)
	end
	local ok, reason = draw(now)
	if not ok then
		stop(view)
		backend.releaseTransient(false)
		return false, reason
	end
	adopt()
	local driver = Instance.new("NumberValue")
	driver.Name = "ShadowTransitionProgress"
	driver.Parent = view.parent
	driver.Value = 0
	view.driver = driver
	view.changed = driver.Changed:Connect(function()
		if view.destroyed or view.running ~= run then
			return
		end
		local drawn, drawFailure = draw(os.clock())
		if not drawn then
			stop(view)
			backend.releaseTransient(false)
			if view.onDiagnostic then
				view.onDiagnostic(drawFailure or "shadow-transition-paint-failed")
			end
		end
	end)
	local remainingDelay = math.max(0, run.started - os.clock())
	local remainingDuration = math.max(0, run.started + duration - os.clock() - remainingDelay)
	local tween = game:GetService("TweenService"):Create(
		driver,
		TweenInfo.new(remainingDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, remainingDelay),
		{ Value = 1 }
	)
	view.tween = tween
	view.completed = tween.Completed:Connect(function(state)
		if view.destroyed or view.running ~= run or state ~= Enum.PlaybackState.Completed then
			return
		end
		local observation = view.playback
		view.playback = nil
		stop(view)
		backend.releaseTransient(false)
		view.current = spec
		local painted, paintFailure = backend.write(spec, prepared, width, height, true)
		if painted then
			backend.releaseTransient(true)
		end
		if observation then
			if painted and not view.destroyed then
				observation.finish()
			else
				observation.cancel()
			end
		end
		if not painted and view.onDiagnostic then
			view.onDiagnostic(paintFailure or "shadow-transition-paint-failed")
		end
	end)
	tween:Play()
	return true, nil
end

function ShadowTransition.destroy<Plan>(view: State<Plan>)
	if view.destroyed then
		return
	end
	view.destroyed = true
	stop(view)
	view.backend.releaseTransient(false)
	view.current = nil
	view.target = nil
	view.onDiagnostic = nil
end

return ShadowTransition
