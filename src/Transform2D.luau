--!strict

local Types = require(script.Parent.Types)
local BoxModel = require(script.Parent.BoxModel)
local Measurements = require(script.Parent.Measurements)
local Translation = require(script.Parent.TranslationTransform)
type Token = Types.ValueToken
export type Result = Translation.Result & { rotation: number?, scale: number? }
-- Optional internal output for composing native animation values without
-- multiplying an already float32-rounded scale. Ordinary resolves allocate none.
export type Matrix = { a: number, b: number, c: number, d: number, x: number, y: number }
export type Function =
	{ kind: "translate", x: number, y: number, xToken: Token?, yToken: Token?, source: Token? }
	| { kind: "rotate", angle: number, source: Token? }
	| { kind: "scale", x: number, y: number, source: Token? }
	| { kind: "matrix", matrix: Matrix, source: Token? }
export type NativeDetails = {
	rawScale: number,
	captureFunctions: boolean?,
	functions: { Function }?,
	prefix: Matrix?,
	prefixContext: boolean?,
	originX: number?,
	originY: number?,
}
local Transform2D = {}
local defaults: { [string]: string } = { perspective = "none", ["transform-style"] = "flat", ["offset-path"] = "none" }

local function significant(tokens: { Token }?): { Token }
	local result = {}
	for _, token in tokens or {} do
		if token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(result, token)
		end
	end
	return result
end
local function keyword(tokens: { Token }?): string?
	local value = significant(tokens)
	return if #value == 1 and value[1].kind == "word" then string.lower(value[1].identifier or value[1].value) else nil
end
local function identity(): Matrix
	return { a = 1, b = 0, c = 0, d = 1, x = 0, y = 0 }
end
local function multiply(a: Matrix, b: Matrix): Matrix
	return {
		a = a.a * b.a + a.c * b.b,
		b = a.b * b.a + a.d * b.b,
		c = a.a * b.c + a.c * b.d,
		d = a.b * b.c + a.d * b.d,
		x = a.a * b.x + a.c * b.y + a.x,
		y = a.b * b.x + a.d * b.y + a.y,
	}
end
local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end
local function sineCosine(degrees: number): (number, number)
	local angle = degrees % 360
	if angle == 0 then
		return 0, 1
	elseif angle == 90 then
		return 1, 0
	elseif angle == 180 then
		return 0, -1
	elseif angle == 270 then
		return -1, 0
	end
	return math.sin(math.rad(angle)), math.cos(math.rad(angle))
end
local function number(token: Token, percentage: boolean?): (number?, string?)
	local value, failure = Measurements.resolve(
		{ token },
		{ percentageDimension = if percentage then "number" else nil, strictPercentageTypes = true }
	)
	if value and value.dimension == "number" and value.percentage == nil then
		return value.value, nil
	end
	return nil, failure or "transform-number-required"
end
local function angle(token: Token): (number?, string?)
	local value, failure = Measurements.resolve({ token }, {})
	if value and (value.dimension == "angle" or (token.kind == "number" and value.value == 0)) then
		return value.value, nil
	end
	return nil, failure or "transform-angle-required"
end
local function arguments(tokens: { Token }?): ({ Token }?, string?)
	local result: { Token } = {}
	local nextValue = true
	for _, token in significant(tokens) do
		if nextValue then
			if token.kind == "div" then
				return nil, "invalid-transform-function-arguments"
			end
			table.insert(result, token)
		elseif token.kind ~= "div" or token.value ~= "," then
			return nil, "comma-separated-transform-arguments-required"
		end
		nextValue = not nextValue
	end
	return if nextValue then nil else result, if nextValue then "invalid-transform-function-arguments" else nil
end
local function rotation(parts: { Token }): (number?, string?)
	local axis = 1
	local token: Token?
	if #parts == 1 then
		token = parts[1]
	elseif #parts == 2 and parts[1].kind == "word" and string.lower(parts[1].identifier or parts[1].value) == "z" then
		token = parts[2]
	elseif #parts == 4 then
		local x, y, z = number(parts[1]), number(parts[2]), number(parts[3])
		if x ~= 0 or y ~= 0 or z == nil then
			return nil, "nonplanar-rotation-provider-required"
		end
		axis, token = if z == 0 then 0 else (if z < 0 then -1 else 1), parts[4]
	else
		return nil, "nonplanar-rotation-provider-required"
	end
	local value, failure = angle(token :: Token)
	return if value then value * axis else nil, failure
end
local function rotate(degrees: number): Matrix
	local s, c = sineCosine(degrees)
	return { a = c, b = s, c = -s, d = c, x = 0, y = 0 }
end

local function linear(matrix: Matrix, encode: boolean): (number?, number?, number?, string?)
	for _, value in { matrix.a, matrix.b, matrix.c, matrix.d, matrix.x, matrix.y } do
		if not finite(value) then
			return nil, nil, nil, "transform-arithmetic-range-required"
		end
	end
	local largest = math.max(math.abs(matrix.a), math.abs(matrix.b), math.abs(matrix.c), math.abs(matrix.d))
	local nativeScale: number = 0
	if largest > 0 then
		local a, b, c, d = matrix.a / largest, matrix.b / largest, matrix.c / largest, matrix.d / largest
		local first, second = a * a + b * b, c * c + d * d
		if math.abs(first - second) > 1e-12 or math.abs(a * c + b * d) > 1e-12 or a * d - b * c < 0 then
			return nil, nil, nil, "native-affine-transform-provider-required"
		end
		nativeScale = largest * math.sqrt(first)
	end
	local nativeRotation = if largest > 0 then math.deg(math.atan2(matrix.b, matrix.a)) else 0
	local encodedScale = if encode then UDim.new(nativeScale, 0).Scale else nativeScale
	if not finite(encodedScale) or math.abs(encodedScale - nativeScale) > nativeScale * 1e-6 then
		return nil, nil, nil, "native-transform-scale-not-representable"
	end
	local rawScale = nativeScale
	nativeScale = encodedScale
	return nativeScale, nativeRotation, rawScale, nil
end

local function nativeResult(
	matrix: Matrix,
	geometry: BoxModel.Geometry,
	originX: number,
	originY: number,
	context: boolean,
	nativeScale: number,
	nativeRotation: number
): (Result?, string?)
	local s, c = sineCosine(nativeRotation)
	local centerX, centerY = geometry.width / 2, geometry.height / 2
	-- Native rotation pivots at the scaled border center; UIScale scales from
	-- the frame's top left. Compensate using the CSS reference-box origin.
	local x = matrix.x
		+ originX
		- matrix.a * originX
		- matrix.c * originY
		+ nativeScale * (c * centerX - s * centerY - centerX)
	local y = matrix.y
		+ originY
		- matrix.b * originX
		- matrix.d * originY
		+ nativeScale * (s * centerX + c * centerY - centerY)
	if not finite(x) or not finite(y) then
		return nil, "transform-arithmetic-range-required"
	end
	return { x = x, y = y, rotation = nativeRotation, scale = nativeScale, establishesContext = context }, nil
end

-- The native-affine subset is a positive uniform scale plus a planar rotation.
-- Interpolation uses raw doubles; only actual native painting quantizes scale.
function Transform2D.decompose(matrix: Matrix): (number?, number?, string?)
	local _, rotation, scale, failure = linear(matrix, false)
	return scale, rotation, failure
end

function Transform2D.native(
	matrix: Matrix,
	geometry: BoxModel.Geometry,
	originX: number,
	originY: number,
	establishesContext: boolean?
): (Result?, string?)
	local scale, rotation, _, failure = linear(matrix, true)
	if scale == nil or rotation == nil then
		return nil, failure
	end
	return nativeResult(matrix, geometry, originX, originY, establishesContext ~= false, scale, rotation)
end

function Transform2D.compose(functions: { Function }, start: Matrix?): Matrix
	local matrix = start or identity()
	for _, value in functions do
		local nextMatrix: Matrix
		if value.kind == "translate" then
			nextMatrix = { a = 1, b = 0, c = 0, d = 1, x = value.x, y = value.y }
		elseif value.kind == "rotate" then
			nextMatrix = rotate(value.angle)
		elseif value.kind == "scale" then
			nextMatrix = { a = value.x, b = 0, c = 0, d = value.y, x = 0, y = 0 }
		else
			nextMatrix = value.matrix
		end
		matrix = multiply(matrix, nextMatrix)
	end
	return matrix
end

function Transform2D.resolve(
	style: Types.ComputedStyle,
	geometry: BoxModel.Geometry,
	units: Measurements.Context,
	nativeDetails: NativeDetails?
): (Result?, string?)
	-- Preserve the existing allocation/validation path for untouched and pure
	-- translation boxes. Rotation/scale work is only paid by the new path.
	local translated = if nativeDetails and nativeDetails.captureFunctions
		then nil
		else Translation.resolve(style, geometry, units)
	if translated then
		if nativeDetails then
			nativeDetails.rawScale = 1
		end
		return translated :: Result, nil
	end
	for _, name in
		{
			"transform",
			"translate",
			"rotate",
			"scale",
			"transform-box",
			"perspective",
			"transform-style",
			"offset-path",
		}
	do
		if style.unresolved[name] then
			return nil, `{name}:{style.unresolved[name]}`
		end
	end
	for name, initial in defaults do
		if style.properties[name] and keyword(style.properties[name]) ~= initial then
			return nil, `planar-transform-provider-required:{name}`
		end
	end
	local box = keyword(style.properties["transform-box"])
		or (if not style.properties["transform-box"] then "view-box" else nil)
	local width, height, referenceX, referenceY = geometry.width, geometry.height, 0, 0
	if box == "content-box" or box == "fill-box" then
		width, height, referenceX, referenceY =
			geometry.contentWidth, geometry.contentHeight, geometry.contentX, geometry.contentY
	elseif box ~= "border-box" and box ~= "stroke-box" and box ~= "view-box" then
		return nil, "transform-reference-box-provider-required"
	end
	if not finite(width) or not finite(height) or width < 0 or height < 0 then
		return nil, "invalid-transform-reference-geometry"
	end
	local matrix = identity()
	local context = false
	local function translation(property: string, tokens: { Token }): (Matrix?, string?)
		local values = { [property] = tokens, ["transform-box"] = style.properties["transform-box"] }
		local value, failure = Translation.resolve(
			{ properties = values, variables = {}, priorities = {}, unresolved = {} },
			geometry,
			units
		)
		if not value then
			return nil, failure
		end
		return { a = 1, b = 0, c = 0, d = 1, x = value.x, y = value.y }, nil
	end
	local individual = style.properties.translate
	if individual and keyword(individual) ~= "none" then
		local value, failure = translation("translate", individual)
		if not value then
			return nil, failure
		end
		matrix, context = value, true
	end
	local turn = style.properties.rotate
	if turn and keyword(turn) ~= "none" then
		local value, failure = rotation(significant(turn))
		if value == nil then
			return nil, failure
		end
		matrix, context = multiply(matrix, rotate(value)), true
	end
	local scale = style.properties.scale
	if scale and keyword(scale) ~= "none" then
		local values = significant(scale)
		if #values < 1 or #values > 3 then
			return nil, "invalid-individual-scale"
		end
		local x, xFailure = number(values[1], true)
		local y, yFailure = if values[2] then number(values[2], true) else x, nil
		local z = if values[3] then number(values[3], true) else 1
		if x == nil or y == nil then
			return nil, xFailure or yFailure or "transform-scale-number-required"
		end
		if z ~= 1 then
			return nil, "nonplanar-scale-provider-required"
		end
		matrix, context = multiply(matrix, { a = x, b = 0, c = 0, d = y, x = 0, y = 0 }), true
	end
	local captured: { Function }? = if nativeDetails and nativeDetails.captureFunctions then {} else nil
	local prefix = if captured then table.freeze(matrix) else nil
	local prefixContext = context
	local list = style.properties.transform
	if list and keyword(list) ~= "none" then
		local functions = significant(list)
		if #functions == 0 then
			return nil, "invalid-transform-function-list"
		end
		context = true
		for _, token in functions do
			if token.kind ~= "function" then
				return nil, "transform-function-list-required"
			end
			local name = string.lower(token.value)
			local args, failure = arguments(token.children)
			if not args then
				return nil, failure
			end
			local value: Matrix?
			local descriptor: Function? = nil
			if name:sub(1, 9) == "translate" then
				value, failure = translation("transform", { token })
			elseif (name == "rotate" or name == "rotatez") and #args == 1 then
				local degrees, why = angle(args[1])
				if degrees == nil then
					return nil, why
				end
				value = rotate(degrees)
				if captured then
					descriptor = { kind = "rotate", angle = degrees, source = token }
				end
			elseif name == "rotate3d" and #args == 4 then
				local degrees, why = rotation(args)
				if degrees == nil then
					return nil, why
				end
				value = rotate(degrees)
				if captured then
					descriptor = { kind = "rotate", angle = degrees, source = token }
				end
			elseif name == "matrix" and #args == 6 then
				local components: { number } = {}
				for _, part in args do
					local n, why = number(part)
					if n == nil then
						return nil, why
					end
					table.insert(components, n)
				end
				value = {
					a = components[1],
					b = components[2],
					c = components[3],
					d = components[4],
					x = components[5],
					y = components[6],
				}
			elseif
				(name == "scale" and (#args == 1 or #args == 2))
				or ((name == "scalex" or name == "scaley") and #args == 1)
			then
				local first, why = number(args[1], true)
				local second = if args[2] then number(args[2], true) else first
				if first == nil or second == nil then
					return nil, why or "transform-scale-number-required"
				end
				value = {
					a = if name == "scaley" then 1 else first,
					b = 0,
					c = 0,
					d = if name == "scalex" then 1 else second,
					x = 0,
					y = 0,
				}
			else
				return nil, `transform-function-provider-required:{name}`
			end
			if not value then
				return nil, failure
			end
			if captured then
				if not descriptor then
					if name:sub(1, 9) == "translate" then
						local entry: Function = {
							kind = "translate",
							x = value.x,
							y = value.y,
							source = token,
							xToken = if name == "translate"
									or name == "translatex"
									or name == "translate3d"
								then args[1]
								else nil,
							yToken = if name == "translate" or name == "translate3d"
								then args[2]
								elseif name == "translatey" then args[1]
								else nil,
						}
						descriptor = entry
					elseif name:sub(1, 5) == "scale" then
						local entry: Function = { kind = "scale", x = value.a, y = value.d, source = token }
						descriptor = entry
					else
						local capturedMatrix: Matrix = table.freeze(value)
						local entry: Function = { kind = "matrix", matrix = capturedMatrix, source = token }
						descriptor = entry
					end
				end
				if descriptor then
					table.freeze(descriptor)
					table.insert(captured, descriptor)
				end
			end
			matrix = multiply(matrix, value)
		end
	end
	local nativeScale, nativeRotation, rawScale, linearFailure = linear(matrix, true)
	if nativeScale == nil or nativeRotation == nil or rawScale == nil then
		return nil, linearFailure
	end
	local originX, originY = geometry.width / 2, geometry.height / 2
	if captured or matrix.a ~= 1 or matrix.b ~= 0 or matrix.c ~= 0 or matrix.d ~= 1 then
		if style.unresolved["transform-origin"] then
			return nil, `transform-origin:{style.unresolved["transform-origin"]}`
		end
		local parts = significant(style.properties["transform-origin"])
		if #parts > 3 then
			return nil, "invalid-transform-origin"
		end
		local x, y: Token? = parts[1], parts[2]
		local function axis(token: Token?, basis: number, horizontal: boolean): (number?, string?)
			if not token then
				return basis / 2, nil
			end
			if token.kind == "word" then
				local word = string.lower(token.identifier or token.value)
				if word == "center" then
					return basis / 2, nil
				end
				if word == (if horizontal then "left" else "top") then
					return 0, nil
				end
				if word == (if horizontal then "right" else "bottom") then
					return basis, nil
				end
				return nil, "invalid-transform-origin-keyword"
			end
			local lengths = table.clone(units)
			lengths.strictPercentageTypes, lengths.allowLengthPercentage = true, true
			lengths.percentageDimension, lengths.percentageBasis = "length", basis
			local value, why = Measurements.resolve({ token }, lengths)
			if
				value
				and (
					(value.dimension == "number" and value.value == 0 and token.kind == "number")
					or value.dimension == "length"
				)
			then
				local scalar = Measurements.toScalar(value, lengths)
				return scalar, if scalar == nil then "transform-origin-arithmetic-range-required" else nil
			end
			return nil, why or "transform-origin-length-percentage-required"
		end
		local function vertical(token: Token?): boolean
			return token ~= nil
				and token.kind == "word"
				and (
					string.lower(token.identifier or token.value) == "top"
					or string.lower(token.identifier or token.value) == "bottom"
				)
		end
		local function horizontal(token: Token?): boolean
			return token ~= nil
				and token.kind == "word"
				and (
					string.lower(token.identifier or token.value) == "left"
					or string.lower(token.identifier or token.value) == "right"
				)
		end
		if #parts == 1 and vertical(x) then
			x, y = nil, x
		elseif x and y and x.kind == "word" and y.kind == "word" and (vertical(x) or horizontal(y)) then
			x, y = y, x
		end
		local ox, xFailure = axis(x, width, true)
		local oy, yFailure = axis(y, height, false)
		if ox == nil or oy == nil then
			return nil, xFailure or yFailure
		end
		if parts[3] then
			local lengths = table.clone(units)
			lengths.strictPercentageTypes = true
			local z = Measurements.resolve({ parts[3] }, lengths)
			if
				not z
				or z.percentage ~= nil
				or (z.dimension ~= "length" and not (parts[3].kind == "number" and z.value == 0))
			then
				return nil, "transform-origin-z-length-required"
			end
		end
		originX, originY = referenceX + ox, referenceY + oy
	end
	local result, failure = nativeResult(matrix, geometry, originX, originY, context, nativeScale, nativeRotation)
	if not result then
		return nil, failure
	end
	if nativeDetails then
		nativeDetails.rawScale = rawScale
		if nativeDetails.captureFunctions then
			nativeDetails.functions = table.freeze(captured or {})
			nativeDetails.prefix = prefix
			nativeDetails.prefixContext = prefixContext
			nativeDetails.originX, nativeDetails.originY = originX, originY
		end
	end
	return result, nil
end

return Transform2D
