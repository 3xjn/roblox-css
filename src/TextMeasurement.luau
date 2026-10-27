--!strict

local TextContent = require(script.Parent.TextContent)

export type Shape = { font: Font, size: number, features: string?, direction: string? }
export type Request = { text: string, font: Font, size: number, features: string, direction: string }
export type Provider = (Request) -> (Vector2?, string?)
export type Backend = {
	measureAsync: Provider,
	clear: () -> (),
	destroy: () -> (),
	subscribe: (() -> ()) -> () -> (),
}
export type Reader = (string, Shape) -> (Vector2?, string?)
export type Options = { measureAsync: Provider?, maxEntries: number?, concurrency: number? }
type Entry = { key: string, request: Request, accessed: number, bounds: Vector2?, failure: string?, pending: boolean }

local TextMeasurement = {}
TextMeasurement.__index = TextMeasurement

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function request(text: string, shape: Shape): (Request?, string?)
	if not finite(shape.size) or shape.size < 0 then
		return nil, "invalid-text-size"
	end
	local direction = shape.direction or "ltr"
	if direction ~= "ltr" and direction ~= "rtl" then
		return nil, "invalid-text-direction"
	end
	local contentFailure = TextContent.validateSingleLine(text)
	if contentFailure then
		return nil, contentFailure
	end
	return {
		text = text,
		font = Font.new(shape.font.Family, shape.font.Weight, shape.font.Style),
		size = shape.size,
		features = shape.features or "",
		direction = direction,
	},
		nil
end

local function key(value: Request): string
	return string.format(
		"%q|%d|%d|%.17g|%q|%q|%q",
		value.font.Family,
		value.font.Weight.Value,
		value.font.Style.Value,
		value.size,
		value.features,
		value.direction,
		value.text
	)
end

-- Native shaping bounds only. Neither line-box metrics nor CSS wrapping are
-- available through GetTextBoundsParams. A supplied provider can shape the
-- complete request through another backend, including native view bounds.
function TextMeasurement.measureAsync(value: Request): (Vector2?, string?)
	local contentFailure = TextContent.validateSingleLine(value.text)
	if contentFailure then
		return nil, contentFailure
	end
	if not finite(value.size) or value.size < 0 then
		return nil, "invalid-text-size"
	end
	if value.size == 0 or value.text == "" then
		return Vector2.zero, nil
	end
	if value.features ~= "" or value.direction ~= "ltr" then
		return nil, "shaping-measurement-requires-view-bounds"
	end
	local guiService = game:GetService("GuiService")
	local preference = guiService.PreferredTextSize
	local params = Instance.new("GetTextBoundsParams")
	local ok, bounds = pcall(function(): Vector2?
		params.Text = value.text
		params.Font = value.font
		params.Size = value.size
		-- Match glyph paint's numeric readback tolerance. A clamped integer
		-- must not be cached as the requested fractional/oversized geometry.
		if math.abs(params.Size - value.size) > math.max(1, value.size) * 1e-6 then
			return nil
		end
		params.Width = 0
		params.RichText = false
		return game:GetService("TextService"):GetTextBoundsAsync(params)
	end)
	params:Destroy()
	if guiService.PreferredTextSize ~= preference then
		return nil, "stale-native-text-preference"
	end
	if not ok then
		return nil, `native-text-measurement:{tostring(bounds)}`
	end
	if bounds == nil then
		return nil, "native-text-size-not-representable"
	end
	if not finite(bounds.X) or not finite(bounds.Y) or bounds.X < 0 or bounds.Y < 0 then
		return nil, "invalid-native-text-bounds"
	end
	return bounds, nil
end

function TextMeasurement.new(options: Options?, backend: Backend?): Cache
	local defaults: Options = options or {}
	local native = if defaults.measureAsync == nil then backend else nil
	local maximum, concurrency = defaults.maxEntries or 512, defaults.concurrency or 4
	assert(finite(maximum) and maximum >= 1 and maximum % 1 == 0, "maxEntries must be a positive integer")
	assert(finite(concurrency) and concurrency >= 1 and concurrency % 1 == 0, "concurrency must be a positive integer")
	local self = setmetatable({
		_provider = defaults.measureAsync or (native and native.measureAsync) or TextMeasurement.measureAsync,
		_backend = native,
		_backendSubscription = nil :: (() -> ())?,
		_nativePreferences = defaults.measureAsync == nil or defaults.measureAsync == TextMeasurement.measureAsync,
		_maximum = maximum,
		_concurrency = concurrency,
		_entries = {} :: { [string]: Entry },
		_count = 0,
		_clock = 0,
		_queue = {} :: { [number]: Entry },
		_head = 1,
		_tail = 0,
		_active = 0,
		_scheduled = false,
		_synchronous = false,
		_notifying = false,
		_notificationForced = false,
		_pins = nil :: { [string]: boolean }?,
		_retained = nil :: { [string]: boolean }?,
		_waiting = nil :: { [Entry]: boolean }?,
		_remaining = 0,
		_listeners = {} :: { [() -> ()]: boolean },
		_destroyed = false,
		_preferenceConnection = nil :: RBXScriptConnection?,
		_observationFailure = nil :: string?,
		_observationAttempted = false,
	}, TextMeasurement)
	if native then
		self._backendSubscription = native.subscribe(function()
			self:clear()
		end)
	end
	return self
end

function TextMeasurement._observePreferences(self: Cache)
	if self._observationAttempted or not self._nativePreferences then
		return
	end
	self._observationAttempted = true
	local ok, connection = pcall(function()
		return game:GetService("GuiService"):GetPropertyChangedSignal("PreferredTextSize"):Connect(function()
			self:clear()
		end)
	end)
	if ok then
		self._preferenceConnection = connection
	else
		self._observationFailure = "native-text-preference-observation-unavailable"
	end
end

function TextMeasurement._notify(self: Cache, force: boolean?)
	if self._destroyed then
		return
	end
	self._notificationForced = self._notificationForced or force == true
	if self._notifying then
		return
	end
	self._notifying = true
	-- Resource completion can start another synchronous layout/read batch. A
	-- next-turn notification breaks that chain without a recurring retry timer.
	task.delay(0, function()
		self._notifying = false
		local forced = self._notificationForced
		self._notificationForced = false
		if self._destroyed or (self._remaining > 0 and not forced) then
			return
		end
		for listener in table.clone(self._listeners) do
			if self._destroyed then
				break
			end
			if self._listeners[listener] then
				listener()
			end
		end
	end)
end

function TextMeasurement._settled(self: Cache, entry: Entry)
	if self._retained and not self._retained[entry.key] then
		return
	end
	local waiting = self._waiting
	if waiting then
		if not waiting[entry] then
			return
		end
		waiting[entry] = nil
		self._remaining -= 1
		if entry.failure then
			-- A required failure can be reported without waiting for slower work.
			table.clear(waiting)
			self._remaining = 0
		end
		if self._remaining > 0 then
			return
		end
	end
	self:_notify()
end

function TextMeasurement._schedule(self: Cache, nextTurn: boolean?)
	if self._destroyed or self._scheduled or self._active >= self._concurrency or self._head > self._tail then
		return
	end
	self._scheduled = true
	local function pump()
		if self._destroyed then
			self._scheduled = false
			return
		end
		local work = 0
		-- Keep the pump owned while starting workers. A synchronous provider can
		-- finish immediately; it must not recursively schedule the next pump.
		while self._active < self._concurrency and self._head <= self._tail and work < 64 and not self._destroyed do
			work += 1
			local entry = self._queue[self._head]
			self._queue[self._head] = nil
			self._head += 1
			if self._entries[entry.key] ~= entry then
				continue
			end
			self._active += 1
			task.spawn(function()
				if self._destroyed or self._entries[entry.key] ~= entry then
					self._active -= 1
					self:_schedule()
					return
				end
				local ok, bounds, failure = pcall(self._provider, entry.request)
				self._active -= 1
				if not self._destroyed and self._entries[entry.key] == entry then
					entry.pending = false
					if not ok then
						entry.failure = `text-measurement-provider:{tostring(bounds)}`
					elseif typeof(bounds) == "Vector2" then
						if finite(bounds.X) and finite(bounds.Y) and bounds.X >= 0 and bounds.Y >= 0 then
							entry.bounds = bounds
						else
							entry.failure = "invalid-text-measurement-provider-bounds"
						end
					else
						entry.failure = failure or "text-measurement-provider-returned-no-bounds"
					end
					self:_settled(entry)
				end
				self:_schedule()
			end)
		end
		if self._head > self._tail then
			self._head, self._tail = 1, 0
		end
		self._scheduled = false
		-- Only known queued work schedules another turn; completion events own
		-- blocked/concurrent work. Large batches yield after bounded work.
		self:_schedule(true)
	end
	if nextTurn then
		task.delay(0, pump)
	else
		task.defer(pump)
	end
end

function TextMeasurement.get(self: Cache, text: string, shape: Shape): (Vector2?, string?)
	if self._destroyed then
		return nil, "text-measurement-cache-destroyed"
	end
	local value, failure = request(text, shape)
	if not value then
		return nil, failure
	end
	if value.size == 0 or value.text == "" then
		return Vector2.zero, nil
	end
	self:_observePreferences()
	if self._observationFailure then
		return nil, self._observationFailure
	end
	local identity = key(value)
	self._clock += 1
	local previous = self._entries[identity]
	if self._synchronous and (not previous or previous.pending) then
		-- Keep the real shaping request in flight. The fallback is provisional
		-- and must never poison the cache for a different font or provider.
		self._synchronous = false
		local ok, problem = pcall(function() self:get(text, shape) end)
		self._synchronous = true
		if not ok then error(problem, 0) end
		local measured, bounds = pcall(function()
			return game:GetService("TextService"):GetTextSize(value.text, value.size, Enum.Font.SourceSans, Vector2.new(1000000, 10000))
		end)
		if not measured then return nil, `native-text-measurement:{tostring(bounds)}` end
		return bounds, nil
	end
	if previous then
		previous.accessed = self._clock
		if self._pins then
			self._pins[identity] = true
		end
		if not self._synchronous or not previous.pending then
			return previous.bounds, if previous.pending then "pending-text-measurement" else previous.failure
		end
		-- Supersede a queued or in-flight request. Its identity check prevents
		-- the older worker from overwriting the synchronous result.
		self._entries[identity] = nil
		self._count -= 1
	end
	if self._count >= self._maximum then
		local oldest: Entry? = nil
		for candidate, entry in self._entries do
			if
				(not self._pins or not self._pins[candidate])
				and (not self._retained or not self._retained[candidate])
				and (not oldest or entry.accessed < oldest.accessed)
			then
				oldest = entry
			end
		end
		if not oldest then
			return nil, "text-measurement-working-set-exceeds-capacity"
		end
		self._entries[oldest.key] = nil
		self._count -= 1
	end
	local entry: Entry = { key = identity, request = value, accessed = self._clock, pending = true }
	self._entries[identity] = entry
	self._count += 1
	if self._pins then
		self._pins[identity] = true
	end
	self._tail += 1
	self._queue[self._tail] = entry
	if self._tail - self._head + 1 > self._maximum * 2 then
		local queued: { [number]: Entry } = {}
		local count = 0
		for index = self._head, self._tail do
			local candidate = self._queue[index]
			if self._entries[candidate.key] == candidate then
				count += 1
				queued[count] = candidate
			end
		end
		self._queue, self._head, self._tail = queued, 1, count
	end
	self:_schedule()
	return nil, "pending-text-measurement"
end

function TextMeasurement.setSynchronous(self: Cache, enabled: boolean)
	self._synchronous = enabled
end

function TextMeasurement.beginPass(self: Cache)
	assert(not self._destroyed, "Text measurement cache has been destroyed")
	assert(not self._pins, "Text measurement passes cannot nest")
	self._retained, self._waiting, self._remaining = nil, nil, 0
	self._pins = {}
end

-- Omitted: legacy progressive notifications for every cached request.
-- false: observe only this pass's requests; true: also batch pending readiness.
function TextMeasurement.endPass(self: Cache, waitForPending: boolean?)
	local pins = self._pins
	self._pins = nil
	self._retained, self._waiting, self._remaining = nil, nil, 0
	if self._destroyed or waitForPending == nil or not pins then
		return
	end
	-- Preserve the latest pass's working set until its retry. Obsolete pending
	-- entries cannot hold this barrier, and required entries cannot be evicted.
	self._retained = pins
	if self._head <= self._tail then
		-- Current pass requests take precedence over obsolete queued work.
		-- Already running native requests keep their bounded concurrency slots.
		local queued: { [number]: Entry } = {}
		for _, required in { true, false } do
			for index = self._head, self._tail do
				local entry = self._queue[index]
				if self._entries[entry.key] == entry and (pins[entry.key] == true) == required then
					table.insert(queued, entry)
				end
			end
		end
		self._queue, self._head, self._tail = queued, 1, #queued
	end
	if not waitForPending then
		return
	end
	local waiting: { [Entry]: boolean } = {}
	for identity in pins do
		local entry = self._entries[identity]
		if entry and entry.pending then
			waiting[entry] = true
			self._remaining += 1
		end
	end
	self._waiting = waiting
end

function TextMeasurement.subscribe(self: Cache, listener: () -> ()): () -> ()
	assert(not self._destroyed, "Text measurement cache has been destroyed")
	self._listeners[listener] = true
	return function()
		self._listeners[listener] = nil
	end
end

function TextMeasurement.clear(self: Cache)
	if self._destroyed then
		return
	end
	if self._backend then
		self._backend.clear()
	end
	self._retained, self._waiting, self._remaining = nil, nil, 0
	if self._count == 0 then
		return
	end
	table.clear(self._entries)
	table.clear(self._queue)
	self._head, self._tail, self._count = 1, 0, 0
	-- In-flight native requests cannot be cancelled. Identity checks prevent
	-- their late results from repopulating cleared or evicted entries.
	self:_notify(true)
end

function TextMeasurement.destroy(self: Cache)
	if self._destroyed then
		return
	end
	self:clear()
	self._destroyed = true
	self._pins = nil
	if self._backendSubscription then
		self._backendSubscription()
		self._backendSubscription = nil
	end
	if self._backend then
		self._backend.destroy()
		self._backend = nil
	end
	if self._preferenceConnection then
		self._preferenceConnection:Disconnect()
		self._preferenceConnection = nil
	end
	table.clear(self._listeners)
end

export type Cache = typeof(setmetatable(
	{} :: {
		_provider: Provider,
		_backend: Backend?,
		_backendSubscription: (() -> ())?,
		_nativePreferences: boolean,
		_maximum: number,
		_concurrency: number,
		_entries: { [string]: Entry },
		_count: number,
		_clock: number,
		_queue: { [number]: Entry },
		_head: number,
		_tail: number,
		_active: number,
		_scheduled: boolean,
		_synchronous: boolean,
		_notifying: boolean,
		_notificationForced: boolean,
		_pins: { [string]: boolean }?,
		_retained: { [string]: boolean }?,
		_waiting: { [Entry]: boolean }?,
		_remaining: number,
		_listeners: { [() -> ()]: boolean },
		_destroyed: boolean,
		_preferenceConnection: RBXScriptConnection?,
		_observationFailure: string?,
		_observationAttempted: boolean,
	},
	TextMeasurement
))

return { create = TextMeasurement.new, measureAsync = TextMeasurement.measureAsync }
