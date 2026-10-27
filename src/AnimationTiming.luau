--!strict

-- Time mapping only. CSS applies animation-timing-function to each property
-- interval between keyframes, not to the whole directed iteration here.
export type Config = {
	duration: number,
	delay: number,
	iterations: number,
	direction: string,
	fill: string,
}
export type Sample = {
	phase: "idle" | "before" | "active" | "after",
	activeTime: number?,
	iteration: number?,
	progress: number?,
	before: boolean?,
}

local AnimationTiming = {}
local directions = { normal = true, reverse = true, alternate = true, ["alternate-reverse"] = true }
local fills = { none = true, forwards = true, backwards = true, both = true }
local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

-- localTime is owned by playback. A paused clock supplies its held time; the
-- sampler neither reads os.clock() nor creates a timer/listener/native object.
function AnimationTiming.sample(config: Config, localTime: number?): (Sample?, string?)
	if localTime == nil then
		return { phase = "idle" }, nil
	end
	if not finite(localTime) then
		return nil, "animation-local-time-range-required"
	elseif not finite(config.duration) or config.duration < 0 then
		return nil, "animation-duration-range-provider-required"
	elseif not finite(config.delay) then
		return nil, "animation-delay-range-provider-required"
	elseif config.iterations ~= config.iterations or config.iterations < 0 then
		return nil, "animation-iteration-count-range-provider-required"
	elseif not directions[config.direction] or not fills[config.fill] then
		return nil, "animation-timing-keyword-required"
	end
	local activeDuration = if config.duration == 0 or config.iterations == 0
		then 0
		else config.duration * config.iterations
	local endTime = math.max(config.delay + activeDuration, 0)
	local beforeBoundary = math.max(math.min(config.delay, endTime), 0)
	local afterBoundary = math.max(math.min(config.delay + activeDuration, endTime), 0)
	local phase: "before" | "active" | "after" = if localTime < beforeBoundary
		then "before"
		elseif localTime >= afterBoundary then "after"
		else "active"
	local activeTime: number?
	if phase == "before" then
		if config.fill == "backwards" or config.fill == "both" then
			activeTime = math.max(localTime - config.delay, 0)
		end
	elseif phase == "after" then
		if config.fill == "forwards" or config.fill == "both" then
			activeTime = math.max(math.min(localTime - config.delay, activeDuration), 0)
		end
	else
		activeTime = localTime - config.delay
	end
	if activeTime == nil then
		return { phase = phase }, nil
	elseif not finite(activeTime) then
		return nil, "animation-timing-arithmetic-range-required"
	end
	local overall = if config.duration == 0
		then (if phase == "before" then 0 else config.iterations)
		else activeTime / config.duration
	if overall == math.huge and config.duration ~= 0 then
		return nil, "animation-timing-arithmetic-range-required"
	end
	local progress = if overall == math.huge then 0 else overall % 1
	if progress == 0 and phase ~= "before" and activeTime == activeDuration and config.iterations ~= 0 then
		progress = 1
	end
	local iteration = if phase == "after" and config.iterations == math.huge
		then math.huge
		else math.floor(overall) - (if progress == 1 then 1 else 0)
	local reverse = config.direction == "reverse"
	if config.direction == "alternate" or config.direction == "alternate-reverse" then
		if iteration ~= math.huge and iteration >= 2 ^ 53 then
			return nil, "animation-iteration-parity-range-required"
		end
		local parity = iteration + (if config.direction == "alternate-reverse" then 1 else 0)
		reverse = iteration ~= math.huge and parity % 2 ~= 0
	end
	return {
		phase = phase,
		activeTime = activeTime,
		iteration = iteration,
		progress = if reverse then 1 - progress else progress,
		before = (phase == "before" and not reverse) or (phase == "after" and reverse),
	},
		nil
end

return AnimationTiming
