--!strict

local Types = require(script.Parent.Types)
local BoxModel = require(script.Parent.BoxModel)
local AbsolutePosition = require(script.Parent.AbsolutePosition)

type Data = { [string]: any }
type Entry = {
	token: {},
	style: Types.ComputedStyle,
	tag: string,
	context: Data,
	metrics: BoxModel.Metrics,
	used: AbsolutePosition.Rect,
}
export type Cache = { [Types.Node]: Entry }

local PositionedSizing = {}

local function freezeResults(metrics: BoxModel.Metrics, used: AbsolutePosition.Rect)
	for _, margin in metrics.margin do
		table.freeze(margin)
	end
	table.freeze(metrics.margin)
	table.freeze(metrics.padding)
	table.freeze(metrics.border)
	table.freeze(metrics)
	table.freeze(used)
end

-- Only owned scalar records enter this snapshot. Opaque/future inputs retain
-- normal calculation rather than being certified by reference equality.
local function capture(value: any, depth: number): (any, boolean)
	if type(value) ~= "table" then
		local kind = type(value)
		return value, kind == "number" or kind == "string" or kind == "boolean" or kind == "nil"
	end
	if depth == 0 or getmetatable(value) ~= nil then
		return nil, false
	end
	local copy = {}
	for key, item in value do
		if type(key) ~= "string" then
			return nil, false
		end
		local owned, ok = capture(item, depth - 1)
		if not ok then
			return nil, false
		end
		copy[key] = owned
	end
	return table.freeze(copy), true
end

local function same(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	elseif type(a) ~= "table" then
		return a == b and (type(a) ~= "number" or a ~= 0 or 1 / a == 1 / b)
	elseif getmetatable(b) ~= nil then
		return false
	end
	for key, value in a do
		if not same(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- The built-in formatter opts in with its immutable computed-style contract
-- and resource epoch. Only this pure used-size calculation is retained;
-- placement, containing-block discovery and descendant formatting stay live.
function PositionedSizing.resolve(
	previous: Cache?,
	current: Cache?,
	node: Types.Node,
	style: Types.ComputedStyle,
	context: AbsolutePosition.Context
): (BoxModel.Metrics?, AbsolutePosition.Rect?, string?, {}?)
	local entry = previous and previous[node]
	if current and entry and entry.style == style and entry.tag == node.tag and same(entry.context, context) then
		current[node] = entry
		return entry.metrics, entry.used, nil, entry.token
	end
	local metrics, reason = BoxModel.resolveMetrics(style, {
		lengths = context.lengths,
		containingInlineSize = context.width,
	})
	if not metrics then
		return nil, nil, reason, nil
	end
	local used, failure = AbsolutePosition.resolve(style, metrics, context)
	local token: {}? = nil
	if current and used then
		local owned, ok = capture(context, 4)
		if ok then
			-- The caller copies metrics before constructing a scene box. Freeze
			-- our owned result so a future formatter edit cannot corrupt reuse.
			freezeResults(metrics, used)
			token = {}
			current[node] = {
				token = token,
				style = style,
				tag = node.tag,
				context = owned,
				metrics = metrics,
				used = used,
			}
		end
	end
	return metrics, used, failure, token
end

return PositionedSizing
