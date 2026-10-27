--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local Transform = require(script.Parent.Transform2D)
local BoxModel = require(script.Parent.BoxModel)
local Translation = require(script.Parent.TranslationTransform)
local TransformBounds = require(script.Parent.TransformBounds)

local AnimationValues = {}
export type Point = { x: number, y: number }
export type Value = number | Point
export type Context = { geometry: BoxModel.Geometry, units: Measurements.Context, style: Types.ComputedStyle }
export type Range = { minimum: number, maximum: number }
export type Model = {
	cx: number,
	ax: number,
	bx: number,
	cy: number,
	ay: number,
	by: number,
	rotation: number,
	direction: number,
	scale: number,
	width: number,
	height: number,
	rotating: boolean,
	scaleDriven: boolean?,
	zeroX: number?,
	zeroY: number?,
	rawScale: number?,
	centerAX: number?,
	centerBX: number?,
	centerAY: number?,
	centerBY: number?,
}
type Rect = { x: number, y: number, width: number, height: number }
local function parts(tokens: { Types.ValueToken }?): { Types.ValueToken }
	local result = {}
	for _, token in tokens or {} do
		if token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(result, token)
		end
	end
	return result
end
local function angle(token: Types.ValueToken): (number?, string?)
	local value, failure = Measurements.resolve({ token }, {})
	if value and (value.dimension == "angle" or (token.kind == "number" and value.value == 0)) then
		return value.value, nil
	end
	return nil, failure or "animation-angle-required"
end
local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

function AnimationValues.supports(property: string): boolean
	return property == "translate"
		or property == "rotate"
		or property == "transform"
		or property == "opacity"
		or property == "scale"
end

function AnimationValues.resolve(property: string, tokens: { Types.ValueToken }?, context: Context?): (Value?, string?)
	if property == "translate" then
		if not context then
			return nil, "animation-translation-geometry-required"
		end
		local properties: { [string]: { Types.ValueToken } } = {}
		if tokens then
			properties.translate = tokens
		end
		properties["transform-box"] = context.style.properties["transform-box"]
		local style: Types.ComputedStyle = {
			properties = properties,
			unresolved = { ["transform-box"] = context.style.unresolved["transform-box"] },
			variables = {},
			priorities = {},
		}
		local value, failure = Translation.resolve(style, context.geometry, context.units)
		return if value then { x = value.x, y = value.y } else nil, failure
	end
	local values = parts(tokens)
	if property == "scale" then
		if
			not tokens
			or (
				#values == 1
				and values[1].kind == "word"
				and string.lower(values[1].identifier or values[1].value) == "none"
			)
		then
			return 1, nil
		end
		if #values < 1 or #values > 3 then
			return nil, "invalid-individual-scale"
		end
		local function number(token: Types.ValueToken, percentages: boolean?): (number?, string?)
			local value, why = Measurements.resolve(
				{ token },
				{ strictPercentageTypes = true, percentageDimension = if percentages then "number" else nil }
			)
			if value and value.dimension == "number" and value.percentage == nil then
				return value.value, nil
			end
			return nil, why or "animation-scale-number-required"
		end
		local x, why = number(values[1], true)
		local y = if values[2] then number(values[2], true) else x
		local z = if values[3] then number(values[3], true) else 1
		if x == nil or y == nil then
			return nil, why or "animation-scale-number-required"
		end
		if z ~= 1 then
			return nil, "nonplanar-scale-provider-required"
		end
		if math.abs(x - y) > math.max(math.abs(x), math.abs(y)) * 1e-12 then
			return nil, "animation-nonuniform-scale-provider-required"
		end
		return x, nil
	end
	if property == "opacity" then
		if not tokens then
			return 1, nil
		end
		local value, failure =
			Measurements.resolve(values, { percentageDimension = "number", strictPercentageTypes = true })
		if value and value.dimension == "number" and value.percentage == nil then
			return math.clamp(value.value, 0, 1), nil
		end
		return nil, failure or "animation-opacity-number-required"
	end
	if property ~= "transform" and property ~= "rotate" then
		return nil, "animation-property-provider-required:" .. property
	end
	if
		not tokens
		or (
			#values == 1
			and values[1].kind == "word"
			and string.lower(values[1].identifier or values[1].value) == "none"
		)
	then
		return 0, nil
	end
	if property == "rotate" then
		if
			#values == 2
			and values[1].kind == "word"
			and string.lower(values[1].identifier or values[1].value) == "z"
		then
			table.remove(values, 1)
		end
		if #values ~= 1 then
			return nil, "animation-rotation-axis-provider-required"
		end
		return angle(values[1])
	end
	local total = 0
	if #values == 0 then
		return nil, "animation-transform-value-required"
	end
	for _, token in values do
		if
			token.kind ~= "function"
			or (string.lower(token.value) ~= "rotate" and string.lower(token.value) ~= "rotatez")
		then
			return nil, "animation-transform-list-provider-required"
		end
		local args = parts(token.children)
		if #args ~= 1 then
			return nil, "animation-rotation-arguments-required"
		end
		local value, failure = angle(args[1])
		if value == nil then
			return nil, failure
		end
		total += value
		if not finite(total) then
			return nil, "animation-value-arithmetic-range-required"
		end
	end
	return total, nil
end

function AnimationValues.interpolate(a: Value, b: Value, progress: number): (Value?, string?)
	if type(a) == "number" and type(b) == "number" then
		local value = (1 - progress) * a + progress * b
		return if finite(value) then value else nil,
			if finite(value) then nil else "animation-value-arithmetic-range-required"
	elseif type(a) == "table" and type(b) == "table" then
		local x = (1 - progress) * a.x + progress * b.x
		local y = (1 - progress) * a.y + progress * b.y
		if finite(x) and finite(y) then
			return { x = x, y = y }, nil
		end
		return nil, "animation-value-arithmetic-range-required"
	end
	return nil, "animation-value-type-provider-required"
end

-- Keep separate axis bounds so a long vertical motion does not allocate an
-- equally wide opacity surface. The factor includes interval easing overshoot.
function AnimationValues.bound(value: Value, previous: Value?, factor: number?): (Value?, string?)
	local multiplier = factor or 1
	if type(value) == "number" and (previous == nil or type(previous) == "number") then
		local result = math.max(math.abs(value), math.abs(previous or 0)) * multiplier
		return if finite(result) then result else nil,
			if finite(result) then nil else "animation-value-arithmetic-range-required"
	elseif type(value) == "table" and (previous == nil or type(previous) == "table") then
		local x = math.max(math.abs(value.x), if previous then math.abs(previous.x) else 0) * multiplier
		local y = math.max(math.abs(value.y), if previous then math.abs(previous.y) else 0) * multiplier
		if finite(x) and finite(y) then
			return { x = x, y = y }, nil
		end
		return nil, "animation-value-arithmetic-range-required"
	end
	return nil, "animation-value-type-provider-required"
end

function AnimationValues.model(
	style: Types.ComputedStyle,
	controlled: { [string]: boolean },
	geometry: BoxModel.Geometry,
	units: Measurements.Context
): (Model?, string?)
	local properties = table.clone(style.properties)
	local unresolved = table.clone(style.unresolved)
	local current: Types.ComputedStyle = {
		properties = properties,
		unresolved = unresolved,
		variables = style.variables,
		priorities = style.priorities,
	}
	local details: Transform.NativeDetails = { rawScale = 0 }
	local function resolve(): (Transform.Result?, string?)
		return Transform.resolve(current, geometry, units, details)
	end
	if controlled.translate then
		properties.translate = { { kind = "number", value = "0" } }
		unresolved.translate = nil
	end
	local zero: Transform.Result? = nil
	if controlled.scale then
		unresolved.scale = nil
		properties.scale = { { kind = "number", value = "0" } }
		local value, why = resolve()
		if not value then
			return nil, why
		end
		zero = value
		properties.scale = { { kind = "number", value = "1" } }
	end
	local function finish(model: Model, rawScale: number): (Model?, string?)
		if controlled.scale then
			local collapsed = assert(zero)
			model.scaleDriven, model.zeroX, model.zeroY, model.rawScale = true, collapsed.x, collapsed.y, rawScale
			local s, c = math.sin(math.rad(model.rotation)), math.cos(math.rad(model.rotation))
			local halfX, halfY = geometry.width / 2, geometry.height / 2
			model.centerAX, model.centerBX = c * halfX - s * halfY, model.direction * (-s * halfX - c * halfY)
			model.centerAY, model.centerBY = s * halfX + c * halfY, model.direction * (c * halfX - s * halfY)
		end
		for _, value in { model.cx, model.ax, model.bx, model.cy, model.ay, model.by } do
			if not finite(value) then
				return nil, "animation-transform-arithmetic-range-required"
			end
		end
		return model, nil
	end
	if not controlled.rotate and not controlled.transform then
		local value, failure = resolve()
		if not value then
			return nil, failure
		end
		return finish({
			cx = value.x,
			cy = value.y,
			ax = 0,
			bx = 0,
			ay = 0,
			by = 0,
			rotation = value.rotation or 0,
			direction = 0,
			scale = value.scale or 1,
			width = geometry.width,
			height = geometry.height,
			rotating = false,
		}, details.rawScale)
	end
	local function set(property: string, value: number)
		local token: Types.ValueToken = { kind = "dimension", value = tostring(value), unit = "deg" }
		properties[property] = if property == "rotate"
			then { token }
			else { { kind = "function", value = "rotate", children = { token } } }
		unresolved[property] = nil
	end
	if controlled.rotate then
		set("rotate", 0)
	end
	if controlled.transform then
		set("transform", 0)
	end
	local driver = if controlled.rotate then "rotate" else "transform"
	local function at(value: number): (Transform.Result?, string?)
		set(driver, value)
		return resolve()
	end
	local a, why = at(0)
	if not a then
		return nil, why
	end
	local rawScale = details.rawScale
	local b, whyB = at(90)
	if not b then
		return nil, whyB
	end
	local c, whyC = at(180)
	if not c then
		return nil, whyC
	end
	local scale = a.scale or 1
	if
		math.abs((b.scale or 1) - scale) > math.max(scale, 1) * 1e-6
		or math.abs((c.scale or 1) - scale) > math.max(scale, 1) * 1e-6
	then
		return nil, "animation-transform-basis-provider-required"
	end
	local rotation = a.rotation or 0
	local delta = ((b.rotation or 0) - rotation + 180) % 360 - 180
	if scale ~= 0 and math.abs(math.abs(delta) - 90) > 1e-5 then
		return nil, "animation-transform-basis-provider-required"
	end
	local cx, cy = a.x / 2 + c.x / 2, a.y / 2 + c.y / 2
	return finish({
		cx = cx,
		ax = a.x - cx,
		bx = b.x - cx,
		cy = cy,
		ay = a.y - cy,
		by = b.y - cy,
		rotation = rotation,
		direction = if delta < 0 then -1 else 1,
		scale = scale,
		width = geometry.width,
		height = geometry.height,
		rotating = true,
	}, rawScale)
end

function AnimationValues.nativeScale(model: Model, factor: number): (number?, string?)
	if not model.scaleDriven then
		return model.scale, nil
	end
	local value = math.abs(factor) * assert(model.rawScale)
	if not finite(value) then
		return nil, "animation-scale-arithmetic-range-required"
	end
	local encoded = UDim.new(value, 0).Scale
	if not finite(encoded) or math.abs(encoded - value) > value * 1e-6 then
		return nil, "native-transform-scale-not-representable"
	end
	return encoded, nil
end

-- Native scale changes the frame's pivot as well as its size. Keep the CSS
-- collapsed origin fixed and compensate using the actually encoded native scale.
local function scaledParts(
	model: Model,
	factor: number,
	encoded: number
): (number, number, number, number, number, number, number, number)
	local zeroX, zeroY = assert(model.zeroX), assert(model.zeroY)
	local sign = if factor < 0 then -1 else (if factor > 0 then 1 else 0)
	local signed = factor * model.scale
	local turn = encoded * sign - signed
	local cx = zeroX + factor * (model.cx - zeroX) + (signed - encoded) * model.width / 2
	local cy = zeroY + factor * (model.cy - zeroY) + (signed - encoded) * model.height / 2
	local ax, bx, ay, by = 0, 0, 0, 0
	if model.rotating then
		ax, bx = factor * model.ax + turn * assert(model.centerAX), factor * model.bx + turn * assert(model.centerBX)
		ay, by = factor * model.ay + turn * assert(model.centerAY), factor * model.by + turn * assert(model.centerBY)
	else
		cx += turn * assert(model.centerAX)
		cy += turn * assert(model.centerAY)
	end
	local rotation = if encoded == 0 then 0 else model.rotation + (if factor < 0 then 180 else 0)
	return cx, ax, bx, cy, ay, by, rotation, encoded
end

function AnimationValues.position(
	model: Model,
	angleValue: number,
	translation: Point?,
	scaleValue: number?,
	encodedScale: number?
): (number, number, number, number)
	local cx, ax, bx, cy, ay, by, rotation, scale =
		model.cx, model.ax, model.bx, model.cy, model.ay, model.by, model.rotation, model.scale
	if model.scaleDriven then
		local factor = scaleValue or 1
		local encoded = encodedScale
		local why: string? = nil
		if encoded == nil then
			encoded, why = AnimationValues.nativeScale(model, factor)
		end
		assert(encoded ~= nil, why)
		cx, ax, bx, cy, ay, by, rotation, scale = scaledParts(model, factor, encoded)
	end
	local angle = angleValue % 360
	local s, c = math.sin(math.rad(angle)), math.cos(math.rad(angle))
	return cx + ax * c + bx * s + (if translation then translation.x else 0),
		cy + ay * c + by * s + (if translation then translation.y else 0),
		if scale == 0 then 0 else (rotation + model.direction * angle) % 360,
		scale
end

-- A static affine prefix/suffix around one planar rotation has sinusoidal
-- coordinates. Full-turn corner envelopes bound every authored angle/easing.
function AnimationValues.bounds(
	model: Model,
	rect: Rect,
	baseX: number,
	baseY: number,
	translation: Point?,
	scaleRange: Range?
): Rect
	if model.scaleDriven and scaleRange then
		local result: Rect? = nil
		for _, factor in { scaleRange.minimum, scaleRange.maximum } do
			local encoded, why = AnimationValues.nativeScale(model, factor)
			assert(encoded ~= nil, why)
			local sample = table.clone(model)
			sample.cx, sample.ax, sample.bx, sample.cy, sample.ay, sample.by, sample.rotation, sample.scale =
				scaledParts(model, factor, encoded)
			sample.scaleDriven = false
			local value = AnimationValues.bounds(sample, rect, baseX, baseY, translation)
			if result then
				local left, top = math.min(result.x, value.x), math.min(result.y, value.y)
				result = {
					x = left,
					y = top,
					width = math.max(result.x + result.width, value.x + value.width) - left,
					height = math.max(result.y + result.height, value.y + value.height) - top,
				}
			else
				result = value
			end
		end
		local value = assert(result)
		-- Float32 scale rounding is piecewise, unlike the authored linear scale.
		-- Include its bounded representation error between endpoint envelopes.
		local extent =
			math.max(math.abs(rect.x) + rect.width, math.abs(rect.y) + rect.height, model.width, model.height, 1)
		local margin = math.max(math.abs(scaleRange.minimum), math.abs(scaleRange.maximum))
				* assert(model.rawScale)
				* extent
				* 2e-6
			+ 1e-9
		return {
			x = value.x - margin,
			y = value.y - margin,
			width = value.width + 2 * margin,
			height = value.height + 2 * margin,
		}
	end
	local tx, ty = if translation then translation.x else 0, if translation then translation.y else 0
	if not model.rotating then
		local value = TransformBounds.resolve(rect, model.width, model.height, model.rotation, model.scale)
		return {
			x = value.x + model.cx - baseX - tx,
			y = value.y + model.cy - baseY - ty,
			width = value.width + 2 * tx,
			height = value.height + 2 * ty,
		}
	end
	local cx, cy = model.width / 2, model.height / 2
	local c, s = math.cos(math.rad(model.rotation)), math.sin(math.rad(model.rotation))
	local centerX, centerY = model.cx + model.scale * cx - baseX, model.cy + model.scale * cy - baseY
	local left: number = math.huge
	local top: number = math.huge
	local right: number = -math.huge
	local bottom: number = -math.huge
	for _, x in { rect.x, rect.x + rect.width } do
		for _, y in { rect.y, rect.y + rect.height } do
			local dx, dy = x - cx, y - cy
			local a = model.ax + model.scale * (c * dx - s * dy)
			local b = model.bx + model.direction * model.scale * (-s * dx - c * dy)
			local radiusX = math.sqrt(a * a + b * b)
			local ya = model.ay + model.scale * (s * dx + c * dy)
			local yb = model.by + model.direction * model.scale * (c * dx - s * dy)
			local radiusY = math.sqrt(ya * ya + yb * yb)
			left = math.min(left, centerX - radiusX)
			top = math.min(top, centerY - radiusY)
			right = math.max(right, centerX + radiusX)
			bottom = math.max(bottom, centerY + radiusY)
		end
	end
	return { x = left - tx, y = top - ty, width = right - left + 2 * tx, height = bottom - top + 2 * ty }
end

return AnimationValues
