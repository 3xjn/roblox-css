--!strict

local WorkQueue = require(script.Parent.WorkQueue)

export type Sample = { phase: string, seconds: number, succeeded: boolean }
export type Sink = (Sample) -> ()

local Profiler = {}

function Profiler.measure<R...>(sink: Sink?, phase: string, callback: () -> R...): R...
	if not sink then
		return callback()
	end
	WorkQueue.profileBegin("RobloxCss/" .. phase)
	local start = os.clock()
	local paused = WorkQueue.pausedSeconds()
	local function finish(ok: boolean, ...: R...): R...
		local elapsed = os.clock() - start - (WorkQueue.pausedSeconds() - paused)
		WorkQueue.profileEnd()
		local recorded, failure = pcall(sink, { phase = phase, seconds = elapsed, succeeded = ok })
		if not recorded then
			warn(`CSS profiler callback: {tostring(failure)}`)
		end
		if not ok then
			error((...), 0)
		end
		return ...
	end
	return finish(pcall(callback))
end

-- Bind once per operation/factory. Disabled profiling returns the original
-- function, avoiding timing calls and per-call argument/closure allocations.
function Profiler.wrap<T>(sink: Sink?, phase: string, callback: T): T
	if not sink then
		return callback
	end
	local callable = callback :: any
	return (
		function(...: any)
			local arguments = table.pack(...)
			return Profiler.measure(sink, phase, function()
				return callable(table.unpack(arguments, 1, arguments.n))
			end)
		end :: any
	) :: T
end

return Profiler
