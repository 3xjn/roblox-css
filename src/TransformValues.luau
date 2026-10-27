--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local Transform = require(script.Parent.Transform2D)
local BoxModel = require(script.Parent.BoxModel)
type Token = Types.ValueToken
type Matrix = Transform.Matrix

type Operand = { tokens: { Token }, axis: "x" | "y" }
type Term = { operand: Operand, weight: number }
export type Length = { read px: number, read x: number, read y: number, read terms: { Term } }
type Affine = { a: number, b: number, c: number, d: number, x: Length, y: Length }
export type Function =
	{ kind: "translate", x: Length, y: Length }
	| { kind: "rotate", angle: number }
	| { kind: "scale", x: number, y: number }
	| { kind: "matrix", matrix: Affine }
export type Value = { functions: { Function }, none: boolean }
export type Context = {
	geometry: BoxModel.Geometry,
	prefix: Matrix,
	prefixContext: boolean,
	originX: number,
	originY: number,
	width: number,
	height: number,
	cache: { [Operand]: number },
}
type Rect = { x: number, y: number, width: number, height: number }
type Interval = { low: number, high: number }
type IntervalMatrix = { a: Interval, b: Interval, c: Interval, d: Interval, x: Interval, y: Interval }
local Values = {}
local maximumFunctions, maximumOperands = 128, 32
local zero: Length = { px = 0, x = 0, y = 0, terms = {} }
table.freeze(zero.terms)
table.freeze(zero)

local function translation(x: Length, y: Length): Function
	return { kind = "translate", x = x, y = y }
end
local function rotation(angle: number): Function
	return { kind = "rotate", angle = angle }
end
local function scaling(x: number, y: number): Function
	return { kind = "scale", x = x, y = y }
end

local function finite(n: number): boolean
	return n == n and math.abs(n) < math.huge
end
local function constant(n: number): Length
	return if n == 0 then zero else { px = n, x = 0, y = 0, terms = {} }
end
local function sameTokens(a: { Token }, b: { Token }): boolean
	if a == b then
		return true
	end
	if #a ~= #b then
		return false
	end
	for i, x in a do
		local y = b[i]
		if x.kind ~= y.kind or x.value ~= y.value or x.unit ~= y.unit then
			return false
		end
		if (x.children == nil) ~= (y.children == nil) then
			return false
		end
		if x.children and y.children and not sameTokens(x.children, y.children) then
			return false
		end
	end
	return true
end
local function sameOperand(a: Operand, b: Operand): boolean
	return a == b or (a.axis == b.axis and sameTokens(a.tokens, b.tokens))
end
-- The sum is a flat set of immutable operands, never a growing interpolation
-- tree. Rapid interruption/reversal between the same values stays bounded.
local function weighted(a: Length, aw: number, b: Length, bw: number): Length
	if aw == 0 and bw == 1 then
		return b
	elseif aw == 1 and bw == 0 then
		return a
	end
	local px, x, y = a.px * aw + b.px * bw, a.x * aw + b.x * bw, a.y * aw + b.y * bw
	if #a.terms == 0 and #b.terms == 0 then
		if px == 0 and x == 0 and y == 0 then
			return zero
		end
		return { px = px, x = x, y = y, terms = zero.terms }
	end
	local terms: { Term } = {}
	for _, source in { { value = a, weight = aw }, { value = b, weight = bw } } do
		for _, term in source.value.terms do
			local weight = term.weight * source.weight
			local found = false
			for _, old in terms do
				if sameOperand(old.operand, term.operand) then
					old.weight += weight
					found = true
					break
				end
			end
			if not found and weight ~= 0 then
				table.insert(terms, { operand = term.operand, weight = weight })
			end
		end
	end
	for i = #terms, 1, -1 do
		if terms[i].weight == 0 then
			table.remove(terms, i)
		end
	end
	return { px = px, x = x, y = y, terms = terms }
end
local function sameLength(a: Length, b: Length): boolean
	if a == b then
		return true
	end
	if a.px ~= b.px or a.x ~= b.x or a.y ~= b.y or #a.terms ~= #b.terms then
		return false
	end
	for _, term in a.terms do
		local found = false
		for _, other in b.terms do
			if term.weight == other.weight and sameOperand(term.operand, other.operand) then
				found = true
				break
			end
		end
		if not found then
			return false
		end
	end
	return true
end
local function normalized(token: Token, units: Measurements.Context): (Token?, string?)
	local copy: Token = table.clone(token)
	if token.kind == "dimension" then
		local value, why = Measurements.resolve({ token }, units)
		if not value then
			return nil, why
		end
		if value.dimension == "length" then
			copy.kind, copy.value, copy.unit = "dimension", string.format("%.17g", value.value), "px"
		end
	end
	if token.children then
		local children: { Token } = {}
		for _, child in token.children do
			local value, why = normalized(child, units)
			if not value then
				return nil, why
			end
			table.insert(children, value)
		end
		copy.children = table.freeze(children)
	end
	return copy, nil
end
local function length(token: Token?, axis: "x" | "y", units: Measurements.Context): (Length?, string?)
	if not token then
		return zero, nil
	end
	local context = table.clone(units)
	context.percentageBasis, context.percentageDimension = nil, "length"
	context.allowRatio, context.strictPercentageTypes, context.allowLengthPercentage = nil, true, true
	local value = Measurements.resolve({ token }, context)
	if value and value.dimension == "length" then
		return {
			px = value.value,
			x = if axis == "x" then value.percentage or 0 else 0,
			y = if axis == "y" then value.percentage or 0 else 0,
			terms = {},
		},
			nil
	end
	if value and value.dimension == "number" and value.value == 0 then
		return zero, nil
	end
	-- Branch selection for nonlinear length-percentage math remains dependent on
	-- the current reference. Font/viewport/container units are already computed.
	local operand, why = normalized(token, units)
	if not operand then
		return nil, why
	end
	return {
		px = 0,
		x = 0,
		y = 0,
		terms = {
			{ operand = { tokens = table.freeze({ operand }), axis = axis }, weight = 1 },
		},
	},
		nil
end
local function scalar(value: Length, context: Context): (number?, string?)
	local result = value.px + value.x * context.width + value.y * context.height
	for _, term in value.terms do
		local operand = term.operand
		local current = context.cache[operand]
		if current == nil then
			local settings: Measurements.Context = {
				strictPercentageTypes = true,
				allowLengthPercentage = true,
				percentageDimension = "length",
				percentageBasis = if operand.axis == "x" then context.width else context.height,
			}
			local quantity, why = Measurements.resolve(operand.tokens, settings)
			if not quantity then
				return nil, why
			end
			current = Measurements.toScalar(quantity, settings)
			if current == nil or not finite(current) then
				return nil, "transform-length-arithmetic-range-required"
			end
			context.cache[operand] = current
		end
		result += (current :: number) * term.weight
	end
	return if finite(result) then result else nil,
		if finite(result) then nil else "transform-length-arithmetic-range-required"
end
local function affine(matrix: Matrix): Affine
	return { a = matrix.a, b = matrix.b, c = matrix.c, d = matrix.d, x = constant(matrix.x), y = constant(matrix.y) }
end
local function used(matrix: Affine, context: Context): (Matrix?, string?)
	local x, why = scalar(matrix.x, context)
	local y, other = scalar(matrix.y, context)
	if x == nil or y == nil then
		return nil, why or other
	end
	return { a = matrix.a, b = matrix.b, c = matrix.c, d = matrix.d, x = x, y = y }, nil
end
local function linear(matrix: Affine): Matrix
	return { a = matrix.a, b = matrix.b, c = matrix.c, d = matrix.d, x = 0, y = 0 }
end
local function multiply(a: Affine, b: Affine): Affine
	return {
		a = a.a * b.a + a.c * b.b,
		b = a.b * b.a + a.d * b.b,
		c = a.a * b.c + a.c * b.d,
		d = a.b * b.c + a.d * b.d,
		x = weighted(a.x, 1, weighted(b.x, a.a, b.y, a.c), 1),
		y = weighted(a.y, 1, weighted(b.x, a.b, b.y, a.d), 1),
	}
end
local function functionMatrix(value: Function): Affine
	if value.kind == "matrix" then
		return value.matrix
	end
	if value.kind == "translate" then
		return { a = 1, b = 0, c = 0, d = 1, x = value.x, y = value.y }
	end
	if value.kind == "scale" then
		return { a = value.x, b = 0, c = 0, d = value.y, x = zero, y = zero }
	end
	return affine(Transform.compose({ { kind = "rotate", angle = value.angle } }))
end
local function compose(functions: { Function }, start: number?): Affine
	local matrix: Affine = { a = 1, b = 0, c = 0, d = 1, x = zero, y = zero }
	for i = start or 1, #functions do
		matrix = multiply(matrix, functionMatrix(functions[i]))
	end
	return matrix
end
local function identity(example: Function): Function
	if example.kind == "translate" then
		return { kind = "translate", x = zero, y = zero }
	end
	if example.kind == "rotate" then
		return { kind = "rotate", angle = 0 }
	end
	if example.kind == "scale" then
		return { kind = "scale", x = 1, y = 1 }
	end
	return { kind = "matrix", matrix = { a = 1, b = 0, c = 0, d = 1, x = zero, y = zero } }
end
local function pair(a: { Function }, b: { Function }, i: number): (Function, Function)
	local x, y = a[i], b[i]
	if not x then
		x = identity(y)
	end
	if not y then
		y = identity(x)
	end
	return x, y
end
local function components(a: Affine, b: Affine): (number?, number?, number?, number?, string?)
	local sa, ra, why = Transform.decompose(linear(a))
	local sb, rb, other = Transform.decompose(linear(b))
	if sa == nil or ra == nil or sb == nil or rb == nil then
		return nil, nil, nil, nil, why or other
	end
	if ra == 0 then
		ra = 360
	end
	if rb == 0 then
		rb = 360
	end
	if math.abs(ra - rb) > 180 then
		if ra > rb then
			ra -= 360
		else
			rb -= 360
		end
	end
	return sa, ra, sb, rb, nil
end
local function lerp(a: number, b: number, t: number): number
	return (1 - t) * a + t * b
end
local function matrixBlend(a: Affine, b: Affine, t: number): Affine
	local sa, ra, sb, rb, why = components(a, b)
	assert(sa ~= nil and ra ~= nil and sb ~= nil and rb ~= nil, why)
	if sa == 0 or sb == 0 then
		return if t < 0.5 then a else b
	end
	local scale = lerp(sa, sb, t)
	local matrix = affine(Transform.compose({
		{ kind = "rotate", angle = lerp(ra, rb, t) },
		{ kind = "scale", x = scale, y = scale },
	}))
	matrix.x, matrix.y = weighted(a.x, 1 - t, b.x, t), weighted(a.y, 1 - t, b.y, t)
	return matrix
end
function Values.equal(a: Value, b: Value): boolean
	if a == b then
		return true
	end
	if a.none ~= b.none or #a.functions ~= #b.functions then
		return false
	end
	for i, x in a.functions do
		local y = b.functions[i]
		if x.kind ~= y.kind then
			return false
		end
		if x.kind == "translate" and y.kind == "translate" then
			if not sameLength(x.x, y.x) or not sameLength(x.y, y.y) then
				return false
			end
		elseif x.kind == "rotate" and y.kind == "rotate" then
			if x.angle ~= y.angle then
				return false
			end
		elseif x.kind == "scale" and y.kind == "scale" then
			if x.x ~= y.x or x.y ~= y.y then
				return false
			end
		elseif x.kind == "matrix" and y.kind == "matrix" then
			local ma, mb = x.matrix, y.matrix
			if
				ma.a ~= mb.a
				or ma.b ~= mb.b
				or ma.c ~= mb.c
				or ma.d ~= mb.d
				or not sameLength(ma.x, mb.x)
				or not sameLength(ma.y, mb.y)
			then
				return false
			end
		end
	end
	return true
end
function Values.interpolate(a: Value, b: Value, t: number): Value
	if t == 0 then
		return a
	elseif t == 1 or Values.equal(a, b) then
		return b
	end
	local functions: { Function } = {}
	for i = 1, math.max(#a.functions, #b.functions) do
		local x, y = pair(a.functions, b.functions, i)
		local nextFunction: Function
		if x.kind == "translate" and y.kind == "translate" then
			nextFunction = translation(weighted(x.x, 1 - t, y.x, t), weighted(x.y, 1 - t, y.y, t))
		elseif x.kind == "rotate" and y.kind == "rotate" then
			nextFunction = rotation(lerp(x.angle, y.angle, t))
		elseif x.kind == "scale" and y.kind == "scale" then
			nextFunction = scaling(lerp(x.x, y.x, t), lerp(x.y, y.y, t))
		else
			nextFunction =
				{ kind = "matrix", matrix = matrixBlend(compose(a.functions, i), compose(b.functions, i), t) }
			table.insert(functions, nextFunction)
			break
		end
		table.insert(functions, nextFunction)
	end
	return { functions = functions, none = a.none and b.none }
end
function Values.capture(
	style: Types.ComputedStyle,
	geometry: BoxModel.Geometry,
	units: Measurements.Context,
	includeIndividual: boolean?
): (Value?, Context?, string?)
	local details: Transform.NativeDetails = { rawScale = 0, captureFunctions = true }
	local pose, why = Transform.resolve(style, geometry, units, details)
	if not pose then
		return nil, nil, why
	end
	local functions: { Function } = {}
	for _, entry in assert(details.functions) do
		local value: Function
		if entry.kind == "translate" then
			local x, xFailure = length(entry.xToken, "x", units)
			local y, yFailure = length(entry.yToken, "y", units)
			if not x or not y then
				return nil, nil, xFailure or yFailure
			end
			value = translation(x, y)
		elseif entry.kind == "rotate" then
			value = rotation(entry.angle)
		elseif entry.kind == "scale" then
			value = scaling(entry.x, entry.y)
		else
			value = { kind = "matrix", matrix = affine(entry.matrix) }
		end
		table.insert(functions, value)
	end
	local prefix = assert(details.prefix)
	if includeIndividual then
		-- The individual transform properties precede the transform list. Keep
		-- their resolved matrix in the animated value instead of the fixed context.
		table.insert(functions, 1, { kind = "matrix", matrix = affine(prefix) })
		prefix = { a = 1, b = 0, c = 0, d = 1, x = 0, y = 0 }
	end
	if #functions > maximumFunctions then
		return nil, nil, "transform-function-budget-provider-required"
	end
	local context: Context = {
		geometry = geometry,
		prefix = prefix,
		prefixContext = not includeIndividual and details.prefixContext == true,
		originX = assert(details.originX),
		originY = assert(details.originY),
		width = geometry.width,
		height = geometry.height,
		cache = setmetatable({}, { __mode = "k" }),
	}
	local box = style.properties["transform-box"]
	if box then
		for _, token in box do
			if token.kind == "word" and (token.value == "content-box" or token.value == "fill-box") then
				context.width, context.height = geometry.contentWidth, geometry.contentHeight
			end
		end
	end
	return { functions = functions, none = #functions == 0 }, context, nil
end
-- CSSOM's transform property exposes this matrix before transform-origin and
-- the separately resolved translate/rotate/scale properties are applied.
function Values.matrix(value: Value, context: Context): (Matrix?, string?)
	return used(compose(value.functions), context)
end
function Values.resolve(value: Value, context: Context): (Transform.Result?, string?)
	local matrix, why = used(compose(value.functions), context)
	if not matrix then
		return nil, why
	end
	local total = Transform.compose({ { kind = "matrix", matrix = matrix } }, context.prefix)
	return Transform.native(
		total,
		context.geometry,
		context.originX,
		context.originY,
		context.prefixContext or not value.none
	)
end
local function lengthBudget(value: Length): string?
	if #value.terms > maximumOperands then
		return "transform-length-operand-budget-provider-required"
	end
	for _, n in { value.px, value.x, value.y } do
		if not finite(n) then
			return "transform-arithmetic-range-required"
		end
	end
	for _, term in value.terms do
		if not finite(term.weight) then
			return "transform-arithmetic-range-required"
		end
	end
	return nil
end
-- Prove native representability for the interval before changing an active run.
-- Static transforms may still contain cancelling nonuniform operations.
function Values.validate(a: Value, b: Value, context: Context): (boolean, string?, boolean?)
	local prefix, _, prefixFailure = Transform.decompose(context.prefix)
	if prefix == nil then
		return false, prefixFailure, nil
	end
	local operands: { Operand } = {}
	for _, value in { a, b } do
		if #value.functions > maximumFunctions then
			return false, "transform-function-budget-provider-required", nil
		end
		for _, entry in value.functions do
			for _, field in
				if entry.kind == "translate"
					then { entry.x, entry.y }
					elseif entry.kind == "matrix" then { entry.matrix.x, entry.matrix.y }
					else {}
			do
				local why = lengthBudget(field)
				if why then
					return false, why, nil
				end
				for _, term in field.terms do
					local found = false
					for _, operand in operands do
						if sameOperand(operand, term.operand) then
							found = true
							break
						end
					end
					if not found then
						table.insert(operands, term.operand)
					end
				end
			end
		end
	end
	if #operands > maximumOperands then
		return false, "transform-length-operand-budget-provider-required", nil
	end
	local discrete = false
	for i = 1, math.max(#a.functions, #b.functions) do
		local x, y = pair(a.functions, b.functions, i)
		if x.kind == "scale" and y.kind == "scale" then
			if x.x ~= x.y or y.x ~= y.y then
				return false, "transition-nonuniform-scale-provider-required", nil
			end
		elseif x.kind == "matrix" or y.kind == "matrix" or x.kind ~= y.kind then
			local sa, _, sb, _, why = components(compose(a.functions, i), compose(b.functions, i))
			if sa == nil or sb == nil then
				return false, why, nil
			end
			discrete = sa == 0 or sb == 0
			break
		end
	end
	-- Bounds/painting use composed operands too, including ones mixed by matrices.
	local ma, mb = compose(a.functions), compose(b.functions)
	for _, field in { ma.x, ma.y, mb.x, mb.y } do
		local why = lengthBudget(field)
		if why then
			return false, why, nil
		end
		local value, failure = scalar(field, context)
		if value == nil then
			return false, failure, nil
		end
	end
	return true, nil, discrete
end

local function interval(a: number, b: number?): Interval
	return { low = math.min(a, b or a), high = math.max(a, b or a) }
end
local function add(a: Interval, b: Interval): Interval
	return { low = a.low + b.low, high = a.high + b.high }
end
local function product(a: Interval, b: Interval): Interval
	local aa, ab, ba, bb = a.low * b.low, a.low * b.high, a.high * b.low, a.high * b.high
	return { low = math.min(aa, ab, ba, bb), high = math.max(aa, ab, ba, bb) }
end
local function apply(matrix: IntervalMatrix, x: Interval, y: Interval): (Interval, Interval)
	return add(add(product(matrix.a, x), product(matrix.c, y)), matrix.x),
		add(add(product(matrix.b, x), product(matrix.d, y)), matrix.y)
end
local function fixed(m: Matrix): IntervalMatrix
	return {
		a = interval(m.a),
		b = interval(m.b),
		c = interval(m.c),
		d = interval(m.d),
		x = interval(m.x),
		y = interval(m.y),
	}
end

function Values.scaleBound(a: Value, b: Value, context: Context): (number?, string?)
	local maximum, _, why = Transform.decompose(context.prefix)
	if maximum == nil then
		return nil, why
	end
	for i = 1, math.max(#a.functions, #b.functions) do
		local x, y = pair(a.functions, b.functions, i)
		if x.kind == "scale" and y.kind == "scale" then
			maximum *= math.max(math.abs(x.x), math.abs(x.y), math.abs(y.x), math.abs(y.y))
		elseif x.kind == "matrix" or y.kind == "matrix" or x.kind ~= y.kind then
			local sa, _, sb, _, failure = components(compose(a.functions, i), compose(b.functions, i))
			if sa == nil or sb == nil then
				return nil, failure
			end
			maximum *= math.max(sa, sb)
			break
		end
	end
	return if finite(maximum) then maximum else nil,
		if finite(maximum) then nil else "transform-envelope-arithmetic-range-required"
end
function Values.bounds(
	a: Value,
	b: Value,
	context: Context,
	rect: Rect,
	targetX: number,
	targetY: number
): (Rect?, string?)
	local operations: { IntervalMatrix } = {}
	local prefixScale, _, prefixFailure = Transform.decompose(context.prefix)
	if prefixScale == nil then
		return nil, prefixFailure
	end
	local scaleBound = prefixScale
	for i = 1, math.max(#a.functions, #b.functions) do
		local x, y = pair(a.functions, b.functions, i)
		local m: IntervalMatrix
		if x.kind == "translate" and y.kind == "translate" then
			local ax, why = scalar(x.x, context)
			local ay, other = scalar(x.y, context)
			local bx, third = scalar(y.x, context)
			local by, fourth = scalar(y.y, context)
			if ax == nil or ay == nil or bx == nil or by == nil then
				return nil, why or other or third or fourth
			end
			m = fixed({ a = 1, b = 0, c = 0, d = 1, x = 0, y = 0 })
			m.x, m.y = interval(ax, bx), interval(ay, by)
		elseif x.kind == "scale" and y.kind == "scale" then
			scaleBound *= math.max(math.abs(x.x), math.abs(x.y), math.abs(y.x), math.abs(y.y))
			m = fixed({ a = 1, b = 0, c = 0, d = 1, x = 0, y = 0 })
			m.a, m.d = interval(x.x, y.x), interval(x.y, y.y)
		elseif x.kind == "rotate" and y.kind == "rotate" and x.angle == y.angle then
			m = fixed(Transform.compose({ { kind = "rotate", angle = x.angle } }))
		elseif x.kind == "rotate" and y.kind == "rotate" then
			m = {
				a = interval(-1, 1),
				b = interval(-1, 1),
				c = interval(-1, 1),
				d = interval(-1, 1),
				x = interval(0),
				y = interval(0),
			}
		else
			local ma, why = used(compose(a.functions, i), context)
			local mb, other = used(compose(b.functions, i), context)
			if not ma or not mb then
				return nil, why or other
			end
			local sa, _, sb, _, failure = components(affine(ma), affine(mb))
			if sa == nil or sb == nil then
				return nil, failure
			end
			local extent = math.max(sa, sb)
			scaleBound *= extent
			m = {
				a = interval(-extent, extent),
				b = interval(-extent, extent),
				c = interval(-extent, extent),
				d = interval(-extent, extent),
				x = interval(ma.x, mb.x),
				y = interval(ma.y, mb.y),
			}
			table.insert(operations, m)
			break
		end
		table.insert(operations, m)
	end
	local x = interval(rect.x - context.originX, rect.x + rect.width - context.originX)
	local y = interval(rect.y - context.originY, rect.y + rect.height - context.originY)
	for i = #operations, 1, -1 do
		x, y = apply(operations[i], x, y)
	end
	x, y = apply(fixed(context.prefix), x, y)
	local result: Rect = {
		x = x.low + context.originX - targetX,
		y = y.low + context.originY - targetY,
		width = x.high - x.low,
		height = y.high - y.low,
	}
	-- UIScale stores float32. The static resolver accepts at most 1e-6
	-- relative scale error; native pivot compensation leaves that error applied
	-- to local ink points. Include it in the envelope rather than relying on a
	-- rounding accident in the later opacity-surface allocation.
	local radius = math.max(math.abs(rect.x), math.abs(rect.x + rect.width))
		+ math.max(math.abs(rect.y), math.abs(rect.y + rect.height))
	local margin = scaleBound * 1e-6 * radius
		+ 1e-12 * (math.abs(result.x) + math.abs(result.y) + result.width + result.height)
	result.x -= margin
	result.y -= margin
	result.width += 2 * margin
	result.height += 2 * margin
	for _, n in { result.x, result.y, result.width, result.height } do
		if not finite(n) then
			return nil, "transform-envelope-arithmetic-range-required"
		end
	end
	return result, nil
end

return Values
