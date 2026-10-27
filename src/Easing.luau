--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
type Token = Types.ValueToken
export type Point = { input: number, output: number }
export type Curve =
	{ kind: "bezier", x1: number, y1: number, x2: number, y2: number }
	| { kind: "steps", count: number, jump: "start" | "end" | "none" | "both" }
	| { kind: "linear", points: { Point } }
local Easing = {}
local presets: { [string]: { number } } = {
	linear = { 0, 0, 1, 1 },
	ease = { 0.25, 0.1, 0.25, 1 },
	["ease-in"] = { 0.42, 0, 1, 1 },
	["ease-out"] = { 0, 0, 0.58, 1 },
	["ease-in-out"] = { 0.42, 0, 0.58, 1 },
}
local function groups(tokens: { Token }): { { Token } }
	local result: { { Token } } = { {} }
	for _, token in tokens do
		if token.kind == "div" and token.value == "," then
			table.insert(result, {} :: { Token })
		elseif token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(result[#result], token)
		end
	end
	return result
end
local function measured(tokens: { Token }, dimension: string): (number?, string?)
	local value, failure = Measurements.resolve(tokens, {})
	if not value then
		return nil, "easing-computation-pending:" .. (failure or "unknown")
	end
	if value.dimension ~= dimension or value.percentage ~= nil then
		return nil, "invalid-easing-value-type"
	end
	return value.value, nil
end
function Easing.parse(token: Token): (Curve?, string?)
	local name = string.lower(token.value)
	if token.kind == "word" then
		local p = presets[name]
		if p then
			return { kind = "bezier", x1 = p[1], y1 = p[2], x2 = p[3], y2 = p[4] }, nil
		end
		if name == "step-start" or name == "step-end" then
			return { kind = "steps", count = 1, jump = if name == "step-start" then "start" else "end" }, nil
		end
		return nil, "invalid-easing-keyword"
	end
	if token.kind ~= "function" then
		return nil, "invalid-easing-token"
	end
	local args = groups(token.children or {})
	if name == "cubic-bezier" then
		if #args ~= 4 then
			return nil, "invalid-bezier-argument-count"
		end
		local values: { number } = {}
		for index, arg in args do
			local value, failure = measured(arg, "number")
			if value == nil then
				return nil, failure
			end
			if index == 1 or index == 3 then
				if #arg == 1 and arg[1].kind == "function" then
					value = math.clamp(value, 0, 1)
				elseif value < 0 or value > 1 then
					return nil, "invalid-bezier-time-coordinate"
				end
			end
			table.insert(values, value)
		end
		return { kind = "bezier", x1 = values[1], y1 = values[2], x2 = values[3], y2 = values[4] }, nil
	elseif name == "steps" then
		if #args < 1 or #args > 2 or #args[1] ~= 1 then
			return nil, "invalid-steps-arguments"
		end
		local count, failure = measured(args[1], "number")
		if count == nil then
			return nil, failure
		end
		local tokenCount = args[1][1]
		if tokenCount.kind == "function" then
			count = math.max(1, math.floor(count + 0.5))
		elseif tokenCount.kind ~= "number" or not tokenCount.value:match("^[-+]?%d+$") or count < 1 then
			return nil, "invalid-step-count"
		end
		if count > 2147483647 then
			return nil, "easing-budget-provider-required"
		end
		local jump: "start" | "end" | "none" | "both" = "end"
		if args[2] then
			if #args[2] ~= 1 or args[2][1].kind ~= "word" then
				return nil, "invalid-step-position"
			end
			local position = string.lower(args[2][1].value)
			if position == "start" or position == "jump-start" then
				jump = "start"
			elseif position == "end" or position == "jump-end" then
				jump = "end"
			elseif position == "jump-none" then
				jump = "none"
			elseif position == "jump-both" then
				jump = "both"
			else
				return nil, "invalid-step-position"
			end
		end
		if jump == "none" and count < 2 then
			return nil, "invalid-jump-none-count"
		end
		return { kind = "steps", count = count, jump = jump }, nil
	elseif name == "linear" then
		if #args < 2 then
			return nil, "invalid-linear-stop-count"
		end
		if #args > 1024 then
			return nil, "easing-budget-provider-required"
		end
		local stops: { { input: number?, output: number } } = {}
		for _, arg in args do
			local output: number? = nil
			local positions: { number } = {}
			for _, part in arg do
				local value, failure = Measurements.resolve({ part }, {})
				if not value then
					return nil, "easing-computation-pending:" .. (failure or "unknown")
				end
				if value.dimension == "number" and not output then
					output = value.value
				elseif value.dimension == "percentage" and #positions < 2 then
					table.insert(positions, value.value)
				else
					return nil, "invalid-linear-stop"
				end
			end
			if output == nil then
				return nil, "linear-stop-output-required"
			end
			table.insert(stops, { input = positions[1], output = output })
			if positions[2] then
				table.insert(stops, { input = positions[2], output = output })
			end
		end
		if stops[1].input == nil then
			stops[1].input = 0
		end
		if stops[#stops].input == nil then
			stops[#stops].input = 1
		end
		local previous = -math.huge
		for _, stop in stops do
			if stop.input ~= nil then
				stop.input = math.max(stop.input, previous)
				previous = stop.input
			end
		end
		local anchor = 1
		for index = 2, #stops do
			local value = stops[index].input
			if value ~= nil then
				local start = assert(stops[anchor].input)
				for middle = anchor + 1, index - 1 do
					stops[middle].input = start + (value - start) * (middle - anchor) / (index - anchor)
				end
				anchor = index
			end
		end
		local points: { Point } = {}
		for _, stop in stops do
			table.insert(points, { input = assert(stop.input), output = stop.output })
		end
		return { kind = "linear", points = points }, nil
	end
	return nil, "easing-provider-required"
end
local function cubic(t: number, a: number, b: number): number
	return 3 * (1 - t) ^ 2 * t * a + 3 * (1 - t) * t * t * b + t ^ 3
end
function Easing.sample(curve: Curve, progress: number, before: boolean?): number
	if curve.kind == "steps" then
		local step = math.floor(progress * curve.count)
		if curve.jump == "start" or curve.jump == "both" then
			step += 1
		end
		if before and progress * curve.count % 1 == 0 then
			step -= 1
		end
		local jumps = curve.count + (if curve.jump == "both" then 1 elseif curve.jump == "none" then -1 else 0)
		if progress >= 0 then
			step = math.max(0, step)
		end
		if progress <= 1 then
			step = math.min(jumps, step)
		end
		return step / jumps
	elseif curve.kind == "linear" then
		local points = curve.points
		local first, last = points[1], points[#points]
		local a: Point
		local b: Point
		if progress < first.input then
			a, b = first, first
			for index = 2, #points do
				if points[index].input > first.input then
					b = points[index]
					break
				end
			end
		elseif progress >= last.input then
			if progress == last.input then
				return last.output
			end
			a, b = last, last
			for index = #points - 1, 1, -1 do
				if points[index].input < last.input then
					a = points[index]
					break
				end
			end
		else
			local low, high = 1, #points
			while low < high do
				local middle = math.ceil((low + high) / 2)
				if points[middle].input <= progress then
					low = middle
				else
					high = middle - 1
				end
			end
			a, b = points[low], points[low + 1]
		end
		if a.input == b.input then
			return a.output
		end
		return a.output + (b.output - a.output) * (progress - a.input) / (b.input - a.input)
	end
	if progress <= 0 then
		if progress == 0 then return 0 end
		if curve.x1 > 0 then return progress * curve.y1 / curve.x1 end
		if curve.x2 > 0 then return progress * curve.y2 / curve.x2 end
		return 0
	elseif progress >= 1 then
		if progress == 1 then return 1 end
		if curve.x2 < 1 then return 1 + (progress - 1) * (1 - curve.y2) / (1 - curve.x2) end
		if curve.x1 < 1 then return 1 + (progress - 1) * (1 - curve.y1) / (1 - curve.x1) end
		return 1
	end
	-- Diagonal Bezier curves are exactly identity on the unit interval. Avoid
	-- numerical inversion for the common linear animation/transition case.
	if curve.x1 == curve.y1 and curve.x2 == curve.y2 then return progress end
	local low, high = 0, 1
	for _ = 1, 24 do
		local t = (low + high) / 2
		if cubic(t, curve.x1, curve.x2) < progress then
			low = t
		else
			high = t
		end
	end
	return cubic((low + high) / 2, curve.y1, curve.y2)
end
function Easing.bounds(curve: Curve): (number, number)
	local atStart = Easing.sample(curve, 0)
	local atEnd = Easing.sample(curve, 1)
	local minimum: number = math.min(atStart, atEnd)
	local maximum: number = math.max(atStart, atEnd)
	local function include(value: number)
		minimum = math.min(minimum, value)
		maximum = math.max(maximum, value)
	end
	if curve.kind == "bezier" then
		local a = 3 * (1 + 3 * curve.y1 - 3 * curve.y2)
		local b = 6 * (curve.y2 - 2 * curve.y1)
		local c = 3 * curve.y1
		if
			a ~= a
			or b ~= b
			or c ~= c
			or math.abs(a) == math.huge
			or math.abs(b) == math.huge
			or math.abs(c) == math.huge
		then
			return -math.huge, math.huge
		end
		local function root(t: number)
			if t > 0 and t < 1 then
				include(cubic(t, curve.y1, curve.y2))
			end
		end
		if math.abs(a) < 1e-12 then
			if math.abs(b) > 1e-12 then
				root(-c / b)
			end
		else
			local d = b * b - 4 * a * c
			if d ~= d or math.abs(d) == math.huge then
				return -math.huge, math.huge
			end
			if d >= 0 then
				root((-b - math.sqrt(d)) / (2 * a))
				root((-b + math.sqrt(d)) / (2 * a))
			end
		end
	elseif curve.kind == "linear" then
		for _, point in curve.points do
			if point.input >= 0 and point.input <= 1 then
				include(point.output)
			end
		end
	end
	return minimum, maximum
end
return Easing
