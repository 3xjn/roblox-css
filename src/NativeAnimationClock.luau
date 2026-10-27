--!strict

local AnimationTiming = require(script.Parent.AnimationTiming)
local Playback = require(script.Parent.Playback)

type Config = AnimationTiming.Config & { paused: boolean }
type Run = { driver: NumberValue?, tween: Tween?, changed: RBXScriptConnection?, wakeup: thread?, deadline: thread? }

-- A native tween only requests paint while this animation's local time moves.
-- One finite deadline ends finite playback. Nothing scans the scene or polls
-- for external changes, and a held/finished clock has no live driver.
local NativeAnimationClock = {}
NativeAnimationClock.__index = NativeAnimationClock

local function endTime(config: Config): number
	local duration = if config.duration == 0 or config.iterations == 0 then 0 else config.duration * config.iterations
	return math.max(config.delay + duration, 0)
end

local function driverTiming(config: Config): TweenInfo?
	-- Two authored iterations repeat the directed phase for all four CSS
	-- directions. An unrelated fixed driver period could alias at low FPS.
	local period = 2 * config.duration
	local ok, timing = pcall(function()
		return TweenInfo.new(period, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1)
	end)
	if not ok or timing.Time <= 0 or timing.Time == math.huge or math.abs(timing.Time - period) > period * 1e-6 then
		return nil
	end
	return timing
end

local function notify(self: Clock, time: number)
	local ok, failure = pcall(self._paint, time)
	if not ok then
		-- A broken property adapter must not keep throwing on every paint.
		self:destroy()
		error(failure, 0)
	end
end

function NativeAnimationClock.current(self: Clock): number
	return self._held + (if self._started then math.max(0, os.clock() - self._started) else 0)
end

function NativeAnimationClock._stop(self: Clock)
	if self._observedDeadline then
		task.cancel(self._observedDeadline)
		self._observedDeadline = nil
	end
	local run = self._run
	self._run = nil
	if not run then
		return
	end
	if run.changed then
		run.changed:Disconnect()
	end
	if run.wakeup then
		task.cancel(run.wakeup)
	end
	if run.deadline then
		task.cancel(run.deadline)
	end
	if run.tween then
		run.tween:Cancel()
		run.tween:Destroy()
	end
	if run.driver then
		run.driver:Destroy()
	end
end

function NativeAnimationClock._start(self: Clock)
	local config = self._config
	if self._destroyed or not config then
		return
	end
	local finish = endTime(config)
	if not self._paintEnabled then
		self._started = if config.paused then nil else os.clock()
		return
	end
	if config.paused then
		self._started = nil
		notify(self, self._held)
		return
	end
	self._started = os.clock()
	if self._held >= finish then
		notify(self, self._held)
		return
	end
	local run: Run = {}
	self._run = run
	-- Configure owned resources before calling paint. A paint callback may
	-- destroy the native parent under deferred Destroying signal delivery.
	if finish < math.huge then
		run.deadline = task.delay(math.max(0, finish - self:current()), function()
			if self._destroyed or self._run ~= run then
				return
			end
			run.deadline = nil
			self:_stop()
			notify(self, finish)
			if self._playback then
				self._playback.finish()
			end
		end)
	end
	local function startDriver()
		if self._destroyed or self._run ~= run then
			return
		end
		run.wakeup = nil
		if self:current() >= finish then
			return
		end
		local driver = Instance.new("NumberValue")
		driver.Name = "CssAnimationClock"
		driver.Parent = self._parent
		if self._destroyed or self._run ~= run then
			driver:Destroy()
			return
		end
		run.driver = driver
		run.changed = driver.Changed:Connect(function()
			if self._destroyed or self._run ~= run then
				return
			end
			notify(self, math.min(self:current(), finish))
		end)
		local tween = game:GetService("TweenService"):Create(driver, assert(driverTiming(config)), { Value = 1 })
		run.tween = tween
		tween:Play()
		notify(self, self:current())
	end
	if config.duration ~= 0 and config.iterations ~= 0 then
		local waitTime = config.delay - self:current()
		if waitTime > 0 then
			run.wakeup = task.delay(waitTime, startDriver)
			notify(self, self._held)
		else
			startDriver()
		end
	else
		notify(self, self._held)
	end
end

function NativeAnimationClock.new(parent: Instance, paint: (number) -> ()): Clock
	local self: Clock = setmetatable({
		_parent = parent,
		_paint = paint,
		_config = nil :: Config?,
		_held = 0,
		_started = nil :: number?,
		_run = nil :: Run?,
		_playback = nil :: Playback.Controller?,
		_observedDeadline = nil :: thread?,
		_destroying = nil :: RBXScriptConnection?,
		_destroyed = false,
		_paintEnabled = true,
	}, NativeAnimationClock)
	self._destroying = parent.Destroying:Connect(function()
		self:destroy()
	end)
	return self
end

-- Empty keyframe effects have a logical timeline but no paint driver. Only an
-- observer requests their finite completion deadline; paused/infinite effects
-- need no timer. Ordinary painted effects reuse the clock's existing deadline.
function NativeAnimationClock.playback(self: Clock): Playback.Handle?
	local config = self._config
	if self._destroyed or not config then
		return nil
	end
	local observation: Playback.Controller = self._playback
		or Playback.create(
			{ duration = config.duration, delay = config.delay, iterations = config.iterations },
			config.paused
		)
	self._playback = observation
	local finish = endTime(config)
	if not config.paused and self:current() >= finish then
		observation.finish()
	elseif not self._paintEnabled and not config.paused and finish < math.huge and not self._observedDeadline then
		self._observedDeadline = task.delay(math.max(0, finish - self:current()), function()
			self._observedDeadline = nil
			if self._playback == observation and not self._destroyed then
				observation.finish()
			end
		end)
	end
	return observation.handle
end

-- The owner matches animation identities. Config updates retain elapsed time;
-- replacing the animation uses a new clock. Invalid updates retain playback.
function NativeAnimationClock.validate(config: Config, time: number, paintEnabled: boolean?): (boolean, string?)
	local valid, failure = AnimationTiming.sample(config, time)
	if not valid then
		return false, failure
	end
	if
		paintEnabled ~= false
		and not config.paused
		and config.duration ~= 0
		and config.iterations ~= 0
		and time < endTime(config)
		and not driverTiming(config)
	then
		return false, "animation-native-clock-period-required"
	end
	return true, nil
end

function NativeAnimationClock.update(self: Clock, config: Config, paintEnabled: boolean?): (boolean, string?)
	if self._destroyed then
		return false, "animation-clock-destroyed"
	end
	local enabled = paintEnabled ~= false
	local valid, failure = NativeAnimationClock.validate(config, self:current(), enabled)
	if not valid then
		return false, failure
	end
	local previous = self._config
	if
		previous
		and previous.duration == config.duration
		and previous.delay == config.delay
		and previous.iterations == config.iterations
		and previous.paused == config.paused
		and self._paintEnabled == enabled
	then
		self._config = table.clone(config)
		if enabled then
			notify(self, self:current())
		end
		return true, nil
	end
	if self._playback then
		if
			not previous
			or previous.duration ~= config.duration
			or previous.delay ~= config.delay
			or previous.iterations ~= config.iterations
		then
			self._playback.cancel()
			self._playback = nil
		else
			self._playback.pause(config.paused)
		end
	end
	self._held = self:current()
	self._started = nil
	self:_stop()
	self._config = table.clone(config)
	self._paintEnabled = enabled
	self:_start()
	if self._playback then
		self:playback()
	end
	return true, nil
end

function NativeAnimationClock.destroy(self: Clock)
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self._playback then
		self._playback.cancel()
		self._playback = nil
	end
	self:_stop()
	if self._destroying then
		self._destroying:Disconnect()
		self._destroying = nil
	end
	self._config = nil
	self._started = nil
	self._paint = function() end
end

export type Clock = typeof(setmetatable(
	{} :: {
		_parent: Instance,
		_paint: (number) -> (),
		_config: Config?,
		_held: number,
		_started: number?,
		_run: Run?,
		_playback: Playback.Controller?,
		_observedDeadline: thread?,
		_destroying: RBXScriptConnection?,
		_destroyed: boolean,
		_paintEnabled: boolean,
	},
	NativeAnimationClock
))

return NativeAnimationClock
