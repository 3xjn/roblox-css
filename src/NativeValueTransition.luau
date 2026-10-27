--!strict

local Transitions = require(script.Parent.Transitions)
local Playback = require(script.Parent.Playback)

export type Operations<T> = { read equal: (T, T) -> boolean, read interpolate: (T, T, number) -> T }

type Run<T> = {
	read from: T,
	read to: T,
	read reverse: T,
	read factor: number,
	read started: number,
	read duration: number,
	read delay: number,
	read easing: Transitions.Easing,
}

-- Preparing a value is read-only. Geometry/bounds providers can reject it
-- without cancelling the preceding run. Only a later command invalidates the
-- plan; natural completion while a provider yields does not resurrect a run.
export type Plan<T> = {
	read owner: Controller<T>,
	read generation: number,
	read target: T,
	read value: T,
	read run: Run<T>?,
	read retained: boolean,
}

-- Values and operations are immutable; nil is reserved for an unmounted value.
-- CSS timing is separate from property-specific interpolation and painting.
-- A finite native tween supplies notifications; CSS easing samples the value.
local NativeValueTransition = {}
NativeValueTransition.__index = NativeValueTransition

local function sample<T>(run: Run<T>, now: number, operations: Operations<T>): (T, number)
	local progress = if now < run.started
		then 0
		elseif run.duration == 0 then 1
		else math.clamp((now - run.started) / run.duration, 0, 1)
	local eased = if now < run.started then 0 else Transitions.ease(run.easing, progress)
	return operations.interpolate(run.from, run.to, eased), eased
end

function NativeValueTransition._stop<T>(self: Controller<T>)
	if self._playback then
		self._playback.cancel()
		self._playback = nil
	end
	if self._changed then
		self._changed:Disconnect()
		self._changed = nil
	end
	if self._completed then
		self._completed:Disconnect()
		self._completed = nil
	end
	if self._tween then
		self._tween:Cancel()
		self._tween = nil
	end
	if self._driver then
		self._driver:Destroy()
		self._driver = nil
	end
	self._run = nil
end

function NativeValueTransition.new<T>(
	parent: Instance,
	name: string,
	operations: Operations<T>,
	paint: (T) -> (),
	settled: () -> (),
	now: (() -> number)?
): Controller<T>
	local self: Controller<T> = setmetatable({
		_parent = parent,
		_name = name,
		_now = now or os.clock,
		_operations = table.freeze(table.clone(operations)),
		_paint = paint,
		_settled = settled,
		_value = nil :: T?,
		_target = nil :: T?,
		_run = nil :: Run<T>?,
		_playback = nil :: Playback.Controller?,
		_driver = nil :: NumberValue?,
		_tween = nil :: Tween?,
		_changed = nil :: RBXScriptConnection?,
		_completed = nil :: RBXScriptConnection?,
		_destroying = nil :: RBXScriptConnection?,
		_destroyed = false,
		_generation = 0,
	}, NativeValueTransition)
	self._destroying = parent.Destroying:Connect(function()
		self:destroy()
	end)
	return self
end

function NativeValueTransition.current<T>(self: Controller<T>): T?
	return if self._run then sample(self._run, self._now(), self._operations) else self._value
end

function NativeValueTransition.active<T>(self: Controller<T>): boolean
	return self._run ~= nil
end

function NativeValueTransition.playback<T>(self: Controller<T>): Playback.Handle?
	local run = self._run
	if not run or self._destroyed then
		return nil
	end
	local observation: Playback.Controller = self._playback
		or Playback.create({ duration = run.duration, delay = run.delay, iterations = 1 })
	self._playback = observation
	return observation.handle
end

function NativeValueTransition.prepare<T>(self: Controller<T>, target: T, config: Transitions.Config?): Plan<T>?
	if self._destroyed then
		return nil
	end
	assert(target ~= nil, "Transition values must not be nil")
	local destination = target :: T
	local operations = self._operations
	local now = self._now()
	local oldRun = self._run
	local value, progress = self._value, 1
	if oldRun then
		value, progress = sample(oldRun, now, operations)
	end
	if value == nil or not config or config.duration + config.delay <= 0 then
		local plan: Plan<T> = {
			owner = self,
			generation = self._generation,
			target = destination,
			value = destination,
			retained = false,
		}
		return table.freeze(plan)
	end
	local initial = value :: T
	if self._target ~= nil and operations.equal(self._target :: T, destination) and oldRun then
		local plan: Plan<T> = {
			owner = self,
			generation = self._generation,
			target = destination,
			value = initial,
			run = oldRun,
			retained = true,
		}
		return table.freeze(plan)
	end
	local factor, reverse = 1, initial
	if oldRun and operations.equal(oldRun.reverse, destination) then
		factor = math.clamp(math.abs(progress * oldRun.factor + 1 - oldRun.factor), 0, 1)
		reverse = oldRun.to
	end
	local duration = config.duration * factor
	local delay = if config.delay < 0 then config.delay * factor else config.delay
	if operations.equal(initial, destination) or duration + delay <= 0 then
		local plan: Plan<T> = {
			owner = self,
			generation = self._generation,
			target = destination,
			value = destination,
			retained = false,
		}
		return table.freeze(plan)
	end
	local run: Run<T> = {
		from = initial,
		to = destination,
		reverse = reverse,
		factor = factor,
		started = now + delay,
		duration = duration,
		delay = delay,
		easing = config.easing,
	}
	local plan: Plan<T> = {
		owner = self,
		generation = self._generation,
		target = destination,
		value = initial,
		run = run,
		retained = false,
	}
	table.freeze(run)
	return table.freeze(plan)
end

function NativeValueTransition.commit<T>(self: Controller<T>, plan: Plan<T>): boolean
	if self._destroyed or plan.owner ~= self or plan.generation ~= self._generation then
		return false
	end
	self._generation += 1
	local destination = plan.target
	local operations = self._operations
	if plan.retained then
		-- The existing clock may have completed during preflight. Keep its
		-- current state, including terminal completion, rather than restarting.
		self._paint(if self._run then (sample(self._run, self._now(), operations)) else destination)
		return true
	end
	self:_stop()
	self._target = destination
	local run = plan.run
	if not run then
		self._value = destination
		self._paint(destination)
		return true
	end
	self._run = run
	self._value = run.from
	self._paint((sample(run, self._now(), operations)))
	if self._destroyed or self._run ~= run then
		return true
	end
	local driver = Instance.new("NumberValue")
	driver.Name = self._name
	driver.Parent = self._parent
	if self._destroyed or self._run ~= run then
		driver:Destroy()
		return true
	end
	self._driver = driver
	self._changed = driver.Changed:Connect(function()
		if self._destroyed or self._run ~= run then
			return
		end
		local current = sample(run, self._now(), operations)
		self._value = current
		self._paint(current)
	end)
	local remainingDelay = math.max(0, run.started - self._now())
	local remainingDuration = math.max(0, run.started + run.duration - self._now() - remainingDelay)
	local tween = game:GetService("TweenService"):Create(
		driver,
		TweenInfo.new(remainingDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, remainingDelay),
		{ Value = 1 }
	)
	self._tween = tween
	self._completed = tween.Completed:Connect(function(state)
		if self._destroyed or self._run ~= run or state ~= Enum.PlaybackState.Completed then
			return
		end
		local observation = self._playback
		self._playback = nil
		self:_stop()
		self._value = destination
		local ok, failure = pcall(self._paint, destination)
		if observation then
			if ok and not self._destroyed then
				observation.finish()
			else
				observation.cancel()
			end
		end
		if not ok then
			self:destroy()
			error(failure, 0)
		end
		if not self._destroyed then
			self._settled()
		end
	end)
	tween:Play()
	return true
end

function NativeValueTransition.apply<T>(self: Controller<T>, target: T, config: Transitions.Config?)
	local plan = self:prepare(target, config)
	if plan then
		self:commit(plan)
	end
end

function NativeValueTransition.destroy<T>(self: Controller<T>)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self:_stop()
	if self._destroying then
		self._destroying:Disconnect()
		self._destroying = nil
	end
	self._paint = function() end
	self._settled = function() end
end

export type Controller<T> = {
	read _stop: (Controller<T>) -> (),
	read current: (Controller<T>) -> T?,
	read active: (Controller<T>) -> boolean,
	read playback: (Controller<T>) -> Playback.Handle?,
	read apply: (Controller<T>, T, Transitions.Config?) -> (),
	read prepare: (Controller<T>, T, Transitions.Config?) -> Plan<T>?,
	read commit: (Controller<T>, Plan<T>) -> boolean,
	read destroy: (Controller<T>) -> (),
	_parent: Instance,
	_name: string,
	_now: () -> number,
	_operations: Operations<T>,
	_paint: (T) -> (),
	_settled: () -> (),
	_value: T?,
	_target: T?,
	_run: Run<T>?,
	_playback: Playback.Controller?,
	_driver: NumberValue?,
	_tween: Tween?,
	_changed: RBXScriptConnection?,
	_completed: RBXScriptConnection?,
	_destroying: RBXScriptConnection?,
	_destroyed: boolean,
	_generation: number,
}

return { create = NativeValueTransition.new }
