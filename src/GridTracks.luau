--!strict

local Types = require(script.Parent.Types)
local Measurements = require(script.Parent.Measurements)
local GridLine = require(script.Parent.GridLine)
local WorkQueue = require(script.Parent.WorkQueue)

type Token = Types.ValueToken
export type Breadth = { kind: string, tokens: { Token }?, factor: number? }
export type Track = { minimum: Breadth, maximum: Breadth, fitContent: { Token }? }
export type List = { tracks: { Track }, names: { [string]: { number } } }
export type Options = { implicit: boolean?, maximumTracks: number?, lengths: Measurements.Context? }

local GridTracks = {}
local maximumInteger = 9007199254740991

local function significant(tokens: { Token }): { Token }
	local result = {}
	for _, token in tokens do
		if token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(result, token)
		end
	end
	return result
end

local function arguments(token: Token, count: number): ({ { Token } }?, string?)
	local result: { { Token } } = { {} }
	for _, child in significant(token.children or {}) do
		if child.kind == "div" and child.value == "," then
			table.insert(result, {} :: { Token })
		else
			table.insert(result[#result], child)
		end
	end
	if #result ~= count then
		return nil, "invalid-grid-track-function-arguments"
	end
	for _, part in result do
		if #part == 0 then
			return nil, "empty-grid-track-function-argument"
		end
	end
	return result, nil
end

local function length(token: Token): (Breadth?, string?)
	if token.kind == "word" or token.kind == "block" or token.kind == "string" then
		return nil, "grid-track-length-required"
	elseif token.kind == "function" then
		local name = string.lower(token.value)
		if name == "minmax" or name == "fit-content" or name == "repeat" then
			return nil, "invalid-nested-grid-track-function"
		end
	end
	if token.kind == "number" or token.kind == "dimension" or token.kind == "percentage" then
		local literal = tonumber(token.value)
		if literal and literal < 0 then
			return nil, "negative-grid-track-size"
		end
	end
	local tokens: { Token } = { token }
	local dimension, value, failure = Measurements.classify(tokens, { percentageDimension = "length" })
	if not dimension then
		if failure == "incompatible-dimensions" then
			return nil, "grid-track-length-required"
		end
		return nil, `grid-track-length-computation-pending:{failure or "unknown"}`
	end
	if dimension ~= "length" and dimension ~= "percentage" and not (dimension == "number" and value == 0) then
		return nil, "grid-track-length-required"
	end
	if token.kind ~= "function" and value and value < 0 then
		return nil, "negative-grid-track-size"
	end
	return { kind = "length", tokens = tokens }, nil
end

local function breadth(token: Token, flexible: boolean): (Breadth?, string?)
	if token.kind == "word" then
		local name = string.lower(token.identifier or token.value)
		if name == "auto" or name == "min-content" or name == "max-content" then
			return { kind = name }, nil
		end
		return nil, "invalid-grid-track-keyword"
	elseif token.kind == "dimension" and token.unit == "fr" then
		local factor = tonumber(token.value)
		if not flexible or not factor or factor ~= factor or factor < 0 or factor >= math.huge then
			return nil, "invalid-grid-track-flex-factor"
		end
		return { kind = "flex", factor = factor }, nil
	elseif token.kind == "raw" then
		return nil, "grid-track-syntax-provider-required"
	end
	return length(token)
end

local function track(token: Token): (Track?, string?)
	local name = if token.kind == "function" then string.lower(token.value) else ""
	if name == "minmax" then
		local parts, failure = arguments(token, 2)
		if not parts then
			return nil, failure
		end
		if #parts[1] ~= 1 or #parts[2] ~= 1 then
			return nil, "invalid-grid-minmax-breadth"
		end
		local minimum, minFailure = breadth(parts[1][1], false)
		local maximum, maxFailure = breadth(parts[2][1], true)
		if not minimum or not maximum then
			return nil, minFailure or maxFailure
		end
		return { minimum = minimum, maximum = maximum }, nil
	elseif name == "fit-content" then
		local parts, failure = arguments(token, 1)
		if not parts then
			return nil, failure
		elseif #parts[1] ~= 1 then
			return nil, "invalid-grid-fit-content-limit"
		end
		local limit, limitFailure = length(parts[1][1])
		if not limit then
			return nil, limitFailure
		end
		return {
			minimum = { kind = "auto" },
			maximum = { kind = "max-content" },
			fitContent = limit.tokens,
		},
			nil
	end
	local value, failure = breadth(token, true)
	if not value then
		return nil, failure
	end
	return { minimum = if value.kind == "flex" then { kind = "auto" } else value, maximum = value }, nil
end

-- Parse the structured CSS tree once. The layout stage supplies used-length
-- context and content contributions; a track definition is not a used size.
function GridTracks.parse(tokens: { Token }, options: Options?): (List?, string?)
	local settings: Options = options or {}
	local budget = settings.maximumTracks or 4096
	if budget < 1 or budget % 1 ~= 0 or budget >= maximumInteger then
		return nil, "invalid-grid-track-budget"
	end
	local result: List = { tracks = {}, names = {} }
	local parts = significant(tokens)
	if #parts == 1 and parts[1].kind == "word" then
		local name = string.lower(parts[1].identifier or parts[1].value)
		if name == "none" and not settings.implicit then
			return result, nil
		elseif name == "subgrid" then
			return nil, "grid-subgrid-provider-required"
		end
	end
	local function names(token: Token): string?
		if settings.implicit then
			return "grid-auto-tracks-cannot-name-lines"
		end
		for _, child in significant(token.children or {}) do
			local value, failure = GridLine.parse({ child })
			if not value or value.kind ~= "line" or not value.name or value.index ~= nil then
				return failure or "invalid-grid-track-line-name"
			end
			local positions = result.names[value.name]
			if not positions then
				positions = {}
				result.names[value.name] = positions
			end
			local position = #result.tracks + 1
			if positions[#positions] ~= position then
				table.insert(positions, position)
			end
		end
		return nil
	end
	local append: ({ Token }, boolean) -> string?
	append = function(sequence: { Token }, repeating: boolean): string?
		local previousNames = false
		for _, token in sequence do
			WorkQueue.checkpoint()
			if token.kind == "block" and token.value == "[" then
				if previousNames then
					return "adjacent-grid-line-name-blocks"
				end
				local failure = names(token)
				if failure then
					return failure
				end
				previousNames = true
			elseif token.kind == "function" and string.lower(token.value) == "repeat" then
				if repeating or settings.implicit then
					return "invalid-grid-track-repeat-position"
				end
				local args, failure = arguments(token, 2)
				if not args then
					return failure
				elseif #args[1] ~= 1 then
					return "invalid-grid-track-repeat-count"
				end
				local countToken = args[1][1]
				if countToken.kind == "word" then
					local word = string.lower(countToken.identifier or countToken.value)
					if word == "auto-fill" or word == "auto-fit" then
						return `grid-{word}-track-expansion-required`
					end
				end
				if countToken.kind == "number" and not countToken.value:match("^[+]?%d+$") then
					return "invalid-grid-track-repeat-count"
				end
				local quantity, quantityFailure = Measurements.resolve(args[1], settings.lengths or {})
				if not quantity then
					return `grid-track-repeat-count-pending:{quantityFailure or "unknown"}`
				elseif quantity.dimension ~= "number" or quantity.percentage ~= nil then
					return "invalid-grid-track-repeat-count"
				end
				local count = quantity.value
				if countToken.kind == "function" then
					count = math.max(1, math.floor(count + 0.5))
				end
				if count < 1 or count % 1 ~= 0 or count > maximumInteger then
					return "invalid-grid-track-repeat-count"
				elseif count > budget then
					return "grid-track-budget-exceeded"
				end
				local start = #result.tracks
				for _ = 1, count do
					local repeatFailure = append(args[2], true)
					if repeatFailure then
						return repeatFailure
					end
					if #result.tracks == start then
						return "empty-grid-track-repeat"
					end
				end
				previousNames = false
			else
				local value, failure = track(token)
				if not value then
					return failure
				elseif #result.tracks >= budget then
					return "grid-track-budget-exceeded"
				end
				table.insert(result.tracks, value)
				previousNames = false
			end
		end
		return nil
	end
	local failure = append(parts, false)
	if failure or #result.tracks == 0 then
		return nil, failure or "grid-track-list-required"
	end
	return result, nil
end

return GridTracks
