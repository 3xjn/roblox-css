--!strict

export type Runtime = {
	now: () -> number,
	defer: (() -> ()) -> (),
	yieldWork: () -> (),
}
export type Queue = {
	defer: (Queue, () -> ()) -> (),
	destroy: (Queue) -> (),
	flushSync: (Queue) -> (),
	_thread: thread?,
	_sync: boolean,
	_parked: boolean,
	_jobs: { [number]: () -> () },
	_head: number,
	_tail: number,
	_running: boolean,
	_destroyed: boolean,
	_budget: number,
	_runtime: Runtime,
	yields: number,
}
type Context = {
	queue: Queue,
	deadline: number,
	atomic: number,
	guard: (() -> boolean)?,
	paused: number,
	scopes: { string },
}

local WorkQueue = {}
local cancelled = table.freeze({})
local contexts: { [thread]: Context } = setmetatable({}, { __mode = "k" })

function WorkQueue.isCancelled(value: unknown): boolean
	return value == cancelled
end

-- Checkpoints are inert outside an owned work queue. A yield continues actual
-- queued work; there is no frame listener, idle scan or repeating detection task.
function WorkQueue.checkpoint()
	local context = contexts[coroutine.running()]
	if not context or context.atomic > 0 then
		return
	end
	local queue = context.queue
	if queue._destroyed or (context.guard ~= nil and not context.guard()) then
		error(cancelled, 0)
	end
	if queue._runtime.now() >= context.deadline then
		queue.yields += 1
		-- Scope timers describe active work, not the time parked between frames.
		for _ = #context.scopes, 1, -1 do
			debug.profileend()
		end
		local started = queue._runtime.now()
		queue._parked = true
		local ok, failure = pcall(coroutine.yield)
		queue._parked = false
		local now = queue._runtime.now()
		context.paused += now - started
		context.deadline = if queue._sync then math.huge else now + queue._budget
		for _, name in context.scopes do
			debug.profilebegin(name)
		end
		if not ok then
			error(failure, 0)
		end
		if queue._destroyed or (context.guard ~= nil and not context.guard()) then
			error(cancelled, 0)
		end
	end
end

function WorkQueue.pausedSeconds(): number
	local context = contexts[coroutine.running()]
	return if context then context.paused else 0
end

function WorkQueue.profileBegin(name: string)
	local context = contexts[coroutine.running()]
	if context then
		table.insert(context.scopes, name)
	end
	debug.profilebegin(name)
end

function WorkQueue.profileEnd()
	debug.profileend()
	local context = contexts[coroutine.running()]
	if context then
		table.remove(context.scopes)
	end
end

function WorkQueue.guard<R...>(predicate: () -> boolean, callback: () -> R...): R...
	local context = contexts[coroutine.running()]
	if not context then
		return callback()
	end
	local previous = context.guard
	context.guard = function()
		return (previous == nil or previous()) and predicate()
	end
	local function finish(ok: boolean, ...: R...): R...
		-- Inner formatters can catch errors while measuring intrinsic content.
		-- Supersession still wins over a converted result/error from that stale
		-- snapshot. Restore guard ownership even when a predicate itself fails.
		local current = table.pack(pcall(function()
			return not context.queue._destroyed and (context.guard == nil or context.guard())
		end))
		context.guard = previous
		if not current[1] then
			error(current[2], 0)
		elseif not current[2] then
			error(cancelled, 0)
		end
		if not ok then
			error((...), 0)
		end
		return ...
	end
	return finish(pcall(callback))
end

-- Native commit remains indivisible. Check the snapshot immediately before
-- entering this scope; checkpoints inside it cannot expose a half-written UI.
function WorkQueue.atomic<R...>(callback: () -> R...): R...
	local context = contexts[coroutine.running()]
	if not context then
		return callback()
	end
	context.atomic += 1
	local function finish(ok: boolean, ...: R...): R...
		context.atomic -= 1
		if not ok then
			error((...), 0)
		end
		return ...
	end
	return finish(pcall(callback))
end

local start: (Queue) -> ()

local function pump(queue: Queue)
	local thread = coroutine.running()
	contexts[thread] =
		{ queue = queue, deadline = if queue._sync then math.huge else queue._runtime.now() + queue._budget, atomic = 0, paused = 0, scopes = {} }
	local ok, failure = pcall(function()
		while not queue._destroyed and queue._head <= queue._tail do
			WorkQueue.checkpoint()
			local callback = queue._jobs[queue._head]
			queue._jobs[queue._head] = nil
			queue._head += 1
			callback()
		end
	end)
	contexts[thread] = nil
	queue._thread = nil
	queue._running = false
	if queue._head > queue._tail then
		queue._head, queue._tail = 1, 0
	elseif not queue._destroyed then
		-- A failed job does not strand other already queued work.
		queue._running = true
		queue._runtime.defer(function()
			start(queue)
		end)
	end
	if not ok and not WorkQueue.isCancelled(failure) then
		error(failure, 0)
	end
end

local function resumeQueued(queue: Queue, thread: thread)
	if queue._thread ~= thread or coroutine.status(thread) ~= "suspended" then return end
	local ok, failure = coroutine.resume(thread)
	if not ok then error(failure, 0) end
	if queue._thread == thread and queue._parked and coroutine.status(thread) == "suspended" then
		queue._runtime.defer(function()
			queue._runtime.yieldWork()
			resumeQueued(queue, thread)
		end)
	end
end

start = function(queue: Queue)
	if queue._thread or not queue._running or queue._destroyed then return end
	local thread = coroutine.create(function() pump(queue) end)
	queue._thread = thread
	resumeQueued(queue, thread)
end

function WorkQueue.create(budgetMs: number, runtime: Runtime?): Queue
	assert(budgetMs > 0 and budgetMs < math.huge, "Work budget must be a finite positive number of milliseconds")
	local queue: Queue = {
		_jobs = {},
		_head = 1,
		_tail = 0,
		_running = false,
		_thread = nil,
		_sync = false,
		_parked = false,
		_destroyed = false,
		_budget = budgetMs / 1000,
		_runtime = runtime or {
			now = os.clock,
			defer = function(callback)
				task.defer(callback)
			end,
			yieldWork = function()
				task.wait()
			end,
		},
		yields = 0,
		defer = function(self, callback)
			assert(not self._destroyed, "Work queue has been destroyed")
			self._tail += 1
			self._jobs[self._tail] = callback
			if not self._running then
				self._running = true
				self._runtime.defer(function()
					start(self)
				end)
			end
		end,
		flushSync = function(self)
			if self._destroyed then return end
			local thread = self._thread
			if thread and (coroutine.status(thread) ~= "suspended" or not self._parked) then
				error("work-queue-reentrant-flush", 0)
			end
			self._sync = true
			local ok, failure = pcall(function()
				if thread then
					local context = contexts[thread]
					if context then context.deadline = math.huge end
					resumeQueued(self, thread)
				elseif self._head <= self._tail then
					self._running = true
					start(self)
				end
			end)
			self._sync = false
			if not ok then error(failure, 0) end
		end,
		destroy = function(self)
			self._destroyed = true
			table.clear(self._jobs)
			self._head, self._tail = 1, 0
		end,
	}
	return queue
end

return WorkQueue
