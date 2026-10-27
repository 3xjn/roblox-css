--!strict
-- A read-only playback episode. Observation is lazy at each native controller;
-- listeners exist only while a consumer awaits completion, never to scan time.
export type State = "running" | "paused" | "finished" | "canceled"
export type Timing = { read duration: number, read delay: number, read iterations: number }
export type Outcome = "finished" | "canceled"
export type Handle = {
	read state: () -> State,
	read timing: () -> Timing,
	read subscribe: ((Outcome) -> ()) -> () -> (),
}
export type Controller = {
	read handle: Handle,
	read finish: () -> (),
	read cancel: () -> (),
	read pause: (boolean) -> (),
}
type Listener = { callback: ((Outcome) -> ())? }
local Playback = {}

function Playback.create(timing: Timing, paused: boolean?): Controller
	local configuration = table.freeze(table.clone(timing))
	local state: State = if paused then "paused" else "running"
	local listeners: { [Listener]: boolean } = {}
	local function dispatch(listener: Listener, outcome: Outcome)
		task.defer(function()
			local callback = listener.callback
			listener.callback = nil
			if callback then
				callback(outcome)
			end
		end)
	end
	local function settle(outcome: Outcome)
		if state == "finished" or state == "canceled" then
			return
		end
		state = outcome
		local pending = listeners
		listeners = {}
		for listener in pending do
			dispatch(listener, outcome)
		end
	end
	local handle: Handle = table.freeze({
		state = function(): State
			return state
		end,
		timing = function(): Timing
			return table.clone(configuration)
		end,
		subscribe = function(callback: (Outcome) -> ()): () -> ()
			local listener: Listener = { callback = callback }
			if state == "finished" or state == "canceled" then
				dispatch(listener, state :: Outcome)
			else
				listeners[listener] = true
			end
			return function()
				listener.callback = nil
				listeners[listener] = nil
			end
		end,
	})
	return table.freeze({
		handle = handle,
		finish = function()
			settle("finished")
		end,
		cancel = function()
			settle("canceled")
		end,
		pause = function(value: boolean)
			if state == "running" or state == "paused" then
				state = if value then "paused" else "running"
			end
		end,
	})
end
return Playback
