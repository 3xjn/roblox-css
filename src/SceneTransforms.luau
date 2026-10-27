--!strict

local Types = require(script.Parent.Types)
local BoxModel = require(script.Parent.BoxModel)
local Measurements = require(script.Parent.Measurements)
local Transitions = require(script.Parent.Transitions)
local Values = require(script.Parent.TransformValues)
local Native = require(script.Parent.NativeValueTransition)
local Dimensions = require(script.Parent.NativeDimensions)

export type Base = {
	style: Types.ComputedStyle,
	geometry: BoxModel.Geometry,
	units: Measurements.Context,
	value: Values.Value?,
	individual: boolean?,
}
export type Requirement = { context: boolean, rotating: boolean }
export type Interval = { from: Values.Value, to: Values.Value, context: Values.Context }
export type Prepared = {
	target: Values.Value,
	context: Values.Context,
	config: Transitions.Config?,
	plan: Native.Plan<Values.Value>?,
	seed: Values.Value?,
	interval: Interval?,
}
local SceneTransforms = {}

local function zeroTime(tokens: { Types.ValueToken }?): boolean
	if not tokens then
		return true
	end
	return #tokens == 1
		and tokens[1].kind == "dimension"
		and tonumber(tokens[1].value) == 0
		and (tokens[1].unit == "s" or tokens[1].unit == "ms")
end
local function possible(style: Types.ComputedStyle): boolean
	return style.properties.transition ~= nil
		or style.unresolved["transition-duration"] ~= nil
		or style.unresolved["transition-delay"] ~= nil
		or not zeroTime(style.properties["transition-duration"])
		or not zeroTime(style.properties["transition-delay"])
end

local function timed(config: Transitions.Config?): boolean
	return config ~= nil and config.duration + config.delay > 0
end
local function previousValue(base: Base, individual: boolean): (Values.Value?, string?)
	if base.value and (base.individual == true) == individual then
		return base.value, nil
	end
	local value, _, why = Values.capture(base.style, base.geometry, base.units, individual)
	return value, why
end
local function translateStart(before: Values.Value, after: Values.Value): Values.Value
	local old, target = before.functions[1], after.functions[1]
	assert(old and old.kind == "matrix" and target and target.kind == "matrix", "individual transform prefix required")
	local matrix = table.clone(target.matrix)
	matrix.x, matrix.y = old.matrix.x, old.matrix.y
	local functions = table.clone(after.functions)
	functions[1] = { kind = "matrix", matrix = matrix }
	return { functions = functions, none = after.none }
end
local function transition(style: Types.ComputedStyle): (Transitions.Config?, boolean, string?)
	local config, failure = Transitions.resolve(style, "transform")
	if failure then return nil, false, failure end
	if timed(config) then return config, false, nil end
	local translate, why = Transitions.resolve(style, "translate")
	if why then return nil, false, why end
	if timed(translate) then return translate, true, nil end
	return config, false, nil
end
local function rotating(value: Values.Value): boolean
	for _, entry in value.functions do
		if entry.kind == "rotate" and entry.angle ~= 0 then
			return true
		end
		if entry.kind == "scale" and (entry.x < 0 or entry.y < 0) then
			return true
		end
		if entry.kind == "matrix" then
			local m = entry.matrix
			if m.b ~= 0 or m.c ~= 0 or m.a < 0 or m.d < 0 then
				return true
			end
		end
	end
	return false
end

-- Called before layout. Reference sizes affect translations, not the existence
-- of a transform context or a planar rotation. Capture failures are left to the
-- ordinary geometry-aware preparation, which retains the last committed scene.
function SceneTransforms.requirement(
	base: Base?,
	controller: Native.Controller<Values.Value>?,
	style: Types.ComputedStyle
): (Requirement?, string?)
	if not base or not possible(style) then
		return nil, nil
	end
	local config, individual, why = transition(style)
	if why then
		return nil, why
	end
	if not timed(config) then
		return nil, nil
	end
	local before = previousValue(base, individual)
	local after, context = Values.capture(style, base.geometry, base.units, individual)
	if not before or not after or not context then
		local tokens = style.properties.transform
		local hasTransform = tokens ~= nil
			and not (#tokens == 1 and tokens[1].kind == "word" and tokens[1].value == "none")
		return if hasTransform
				or (before ~= nil and not before.none)
				or (controller ~= nil and controller:active())
			then { context = true, rotating = true }
			else nil,
			nil
	end
	if individual then before = translateStart(before, after) end
	local active = controller ~= nil and controller:active()
	if not active and Values.equal(before, after) then
		return nil, nil
	end
	local start = if controller then controller:current() else before
	local valid, _, discrete = Values.validate(start or before, after, context)
	if valid and discrete and not assert(config).allowDiscrete then
		return nil, nil
	end
	local run = if controller then controller._run else nil
	return {
		context = not before.none or not after.none or active,
		rotating = rotating(before) or rotating(after) or (run ~= nil and (rotating(run.from) or rotating(run.to))),
	},
		nil
end

function SceneTransforms.intervalRequirement(interval: Interval?): Requirement?
	return if interval then { context = true, rotating = rotating(interval.from) or rotating(interval.to) } else nil
end

-- No native mutation happens here. Existing owners produce an exact read-only
-- timing plan; a first transition has known static endpoints and is seeded only
-- in the atomic commit, after all scene/surface checks have succeeded.
function SceneTransforms.prepare(
	before: Base?,
	controller: Native.Controller<Values.Value>?,
	style: Types.ComputedStyle,
	geometry: BoxModel.Geometry,
	units: Measurements.Context,
	animated: boolean
): (Base?, Prepared?, string?)
	if not controller and not possible(style) then
		if before and before.style == style and before.geometry == geometry and before.units == units then
			return before, nil, nil
		end
		return { style = style, geometry = geometry, units = units }, nil, nil
	end
	local base: Base = { style = style, geometry = geometry, units = units }
	local config, individual, why = transition(style)
	if why then
		return nil, nil, why
	end
	if not timed(config) and not controller then
		return base, nil, nil
	end
	local target, context, failure = Values.capture(style, geometry, units, individual)
	if not target or not context then
		return nil, nil, failure
	end
	base.value = target
	base.individual = individual
	local program: Prepared = { target = target, context = context, config = config }
	local from: Values.Value?
	local to: Values.Value?
	if controller then
		local plan = assert(controller:prepare(target, config))
		program.plan = plan
		if plan.run then
			from, to = plan.run.from, plan.run.to
		end
	elseif before and timed(config) then
		local initial, reason = previousValue(before, individual)
		if not initial then
			return nil, nil, reason
		end
		if individual then initial = translateStart(initial, target) end
		if not Values.equal(initial, target) then
			program.seed = initial
			from, to = initial, target
		end
	end
	if from and to then
		local valid, reason, discrete = Values.validate(from, to, context)
		if not valid then
			return nil, nil, reason
		end
		if discrete and not assert(config).allowDiscrete then
			program.config, program.seed = nil, nil
			if controller then
				program.plan = controller:prepare(target, nil)
			end
		else
			if animated then
				return nil, nil, "animation-transition-composition-provider-required:transform"
			end
			program.interval = { from = from, to = to, context = context }
		end
	end
	if not program.plan and not program.interval then
		return base, nil, nil
	end
	return base, program, nil
end

function SceneTransforms.needsScale(interval: Interval?): boolean
	if not interval then
		return false
	end
	for _, value in { interval.from, interval.to } do
		for _, entry in value.functions do
			if entry.kind == "scale" and (entry.x ~= 1 or entry.y ~= 1) then
				return true
			end
			if entry.kind == "matrix" then
				local matrix = entry.matrix
				if matrix.a ~= 1 or matrix.b ~= 0 or matrix.c ~= 0 or matrix.d ~= 1 then return true end
			end
		end
	end
	return false
end

-- The position envelope includes native pivot compensation, as well as CSS
-- transformed origin/translation. Even an ungrouped view must prove that every
-- native position/scale in its interval can be encoded before starting a run.
function SceneTransforms.validatePaint(
	program: Prepared,
	reference: Vector2,
	baseX: number,
	baseY: number,
	targetX: number,
	targetY: number
): string?
	local interval = program.interval
	if not interval then
		return nil
	end
	local maximum, why = Values.scaleBound(interval.from, interval.to, interval.context)
	if maximum == nil then
		return why
	end
	local encoded = UDim.new(maximum, 0).Scale
	if encoded ~= encoded or math.abs(encoded) == math.huge or math.abs(encoded - maximum) > maximum * 1e-6 then
		return "native-transform-scale-not-representable"
	end
	local bounds, reason = Values.bounds(
		interval.from,
		interval.to,
		interval.context,
		{ x = 0, y = 0, width = 0, height = 0 },
		targetX,
		targetY
	)
	if not bounds then
		return reason
	end
	local g = interval.context.geometry
	local dx, dy = encoded * (g.width + g.height / 2), encoded * (g.height + g.width / 2)
	for _, axis in
		{
			{ low = baseX + bounds.x - dx, high = baseX + bounds.x + bounds.width + dx, reference = reference.X },
			{ low = baseY + bounds.y - dy, high = baseY + bounds.y + bounds.height + dy, reference = reference.Y },
		}
	do
		-- Endpoint integer offsets alone do not prove that fractional samples
		-- are representable through a zero/subnormal native reference.
		for _, point in { axis.low, axis.high, 0.5 } do
			local value, failure = Dimensions.axis(point, axis.reference)
			if not value then
				return failure
			end
		end
	end
	return nil
end

return SceneTransforms
