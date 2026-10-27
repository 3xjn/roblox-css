--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)

-- Resource providers supply density-corrected CSS pixels, independently of
-- the element's width/height attributes. An empty record means known absence
-- of natural dimensions; nil means metadata has not been supplied yet.
export type Natural = { width: number?, height: number?, ratio: number? }
export type Context = { width: number, height: number, natural: Natural?, lengths: Measurements.Context }
export type Rect = { x: number, y: number, width: number, height: number }
type Axis = { edge: string, offset: Types.ValueToken? }

local ObjectFit = {}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function components(tokens: { Types.ValueToken }?): { Types.ValueToken }
	local result = {}
	for _, token in tokens or {} do
		if token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(result, token)
		end
	end
	return result
end

local function keyword(token: Types.ValueToken): string?
	return if token.kind == "word" then string.lower(token.value) else nil
end

local function axisName(edge: string): string?
	return if edge == "left" or edge == "right" then "x" elseif edge == "top" or edge == "bottom" then "y" else nil
end

local function axis(token: Types.ValueToken, name: string): Axis?
	local word = keyword(token)
	if not word then
		return { edge = "start", offset = token }
	end
	if word == "center" or axisName(word) == name then
		return { edge = word }
	end
	return nil
end

local function position(tokens: { Types.ValueToken }): (Axis?, Axis?, string?)
	local center: Axis = { edge = "center" }
	if #tokens == 0 then
		return center, center, nil
	elseif #tokens == 1 then
		local word = keyword(tokens[1])
		if word and axisName(word) == "y" then
			return center, { edge = word }, nil
		end
		local horizontal = axis(tokens[1], "x")
		return horizontal, center, if horizontal then nil else "invalid-object-position"
	elseif #tokens == 2 then
		local first, second = keyword(tokens[1]), keyword(tokens[2])
		-- Only two keywords may be reordered. A length always occupies its
		-- grammatical horizontal/vertical position in the two-value form.
		if first and second and (axisName(first) == "y" or axisName(second) == "x") then
			local horizontal, vertical = axis(tokens[2], "x"), axis(tokens[1], "y")
			return horizontal, vertical, if horizontal and vertical then nil else "invalid-object-position"
		end
		local horizontal, vertical = axis(tokens[1], "x"), axis(tokens[2], "y")
		return horizontal, vertical, if horizontal and vertical then nil else "invalid-object-position"
	elseif #tokens > 4 then
		return nil, nil, "invalid-object-position"
	end
	local groups: { Axis } = {}
	local index = 1
	while index <= #tokens do
		local word = keyword(tokens[index])
		if not word or (word ~= "center" and not axisName(word)) then
			return nil, nil, "invalid-object-position-edge"
		end
		local group: Axis = { edge = word }
		local nextToken = tokens[index + 1]
		if nextToken and not keyword(nextToken) then
			if word == "center" then
				return nil, nil, "invalid-object-position-center-offset"
			end
			group.offset = nextToken
			index += 1
		end
		table.insert(groups, group)
		index += 1
	end
	if #groups ~= 2 then
		return nil, nil, "invalid-object-position-edge-pairs"
	end
	local horizontal: Axis? = nil
	local vertical: Axis? = nil
	for _, group in groups do
		local name = axisName(group.edge)
		if name == "x" then
			if horizontal then
				return nil, nil, "duplicate-object-position-axis"
			end
			horizontal = group
		elseif name == "y" then
			if vertical then
				return nil, nil, "duplicate-object-position-axis"
			end
			vertical = group
		end
	end
	return horizontal or center, vertical or center, nil
end

local function coordinate(spec: Axis, free: number, lengths: Measurements.Context): (number?, string?)
	if spec.edge == "center" then
		return free / 2, nil
	end
	local offset = 0
	if spec.offset then
		local context = table.clone(lengths)
		context.allowRatio = nil
		context.strictPercentageTypes = true
		context.allowLengthPercentage = true
		context.percentageDimension = "length"
		context.percentageBasis = free
		local value, failure = Measurements.resolve({ spec.offset }, context)
		if not value then
			return nil, failure or "invalid-object-position-offset"
		end
		if value.dimension == "number" and value.value == 0 and spec.offset.kind == "number" then
			offset = 0
		elseif value.dimension == "length" then
			local scalar = Measurements.toScalar(value, context)
			if scalar == nil or not finite(scalar) then
				return nil, "object-position-arithmetic-range-required"
			end
			offset = scalar
		else
			return nil, "object-position-length-percentage-required"
		end
	end
	return if spec.edge == "right" or spec.edge == "bottom" then free - offset else offset, nil
end

-- Computes the painted object rectangle, never the element's layout size.
-- The renderer must clip this rectangle to the element's content box.
function ObjectFit.resolve(style: Types.ComputedStyle, context: Context): (Rect?, string?)
	for _, property in { "object-fit", "object-position" } do
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
	end
	if not finite(context.width) or not finite(context.height) or context.width < 0 or context.height < 0 then
		return nil, "invalid-object-content-size"
	end
	local tokens = components(style.properties["object-fit"])
	local fit = if #tokens == 0 then "fill" elseif #tokens == 1 then keyword(tokens[1]) else nil
	if fit ~= "fill" and fit ~= "contain" and fit ~= "cover" and fit ~= "none" and fit ~= "scale-down" then
		return nil, "invalid-object-fit"
	end
	local width, height = context.width, context.height
	if fit ~= "fill" then
		local natural = context.natural
		if not natural then
			return nil, "object-natural-metadata-provider-required"
		end
		for _, field in { "width", "height", "ratio" } do
			local value = (natural :: { [string]: number? })[field]
			if value ~= nil and (not finite(value) or value <= 0) then
				return nil, "object-positive-natural-dimensions-required"
			end
		end
		local ratio = natural.ratio
		if not ratio and natural.width and natural.height then
			ratio = natural.width / natural.height
		end
		if ratio and (not finite(ratio) or ratio <= 0) then
			return nil, "object-natural-ratio-arithmetic-range-required"
		end
		local function constrained(cover: boolean): (number, number)
			if not ratio then
				return context.width, context.height
			end
			local wide = context.width / ratio >= context.height
			if wide == cover then
				return context.width, context.width / ratio
			end
			return context.height * ratio, context.height
		end
		if fit == "contain" or fit == "cover" then
			width, height = constrained(fit == "cover")
		else
			-- Default sizing with no specified size: natural dimensions first,
			-- ratio-constrained default size only when neither dimension exists.
			if natural.width then
				width = natural.width
				height = natural.height or (if ratio then width / ratio else context.height)
			elseif natural.height then
				height = natural.height
				width = if ratio then height * ratio else context.width
			else
				width, height = constrained(false)
			end
			if fit == "scale-down" then
				local containedWidth, containedHeight = constrained(false)
				-- Without a natural ratio, the contain constraint uses the box;
				-- select a size only when it is no larger on either axis.
				if containedWidth <= width and containedHeight <= height then
					width, height = containedWidth, containedHeight
				elseif containedWidth < width or containedHeight < height then
					return nil, "object-scale-down-incomparable-natural-sizes"
				end
			end
		end
	end
	if not finite(width) or not finite(height) then
		return nil, "object-size-arithmetic-range-required"
	end
	local horizontal, vertical, failure = position(components(style.properties["object-position"]))
	if not horizontal or not vertical then
		return nil, failure
	end
	local x, xFailure = coordinate(horizontal, context.width - width, context.lengths)
	local y, yFailure = coordinate(vertical, context.height - height, context.lengths)
	if x == nil or y == nil then
		return nil, xFailure or yFailure
	end
	if not finite(x) or not finite(y) then
		return nil, "object-position-arithmetic-range-required"
	end
	return { x = x, y = y, width = width, height = height }, nil
end

return ObjectFit
