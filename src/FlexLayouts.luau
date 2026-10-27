--!strict

local Types = require(script.Parent.Types)
local FlexTypes = require(script.Parent.FlexTypes)
local FlexScene = require(script.Parent.FlexScene)
local ListLayout = require(script.Parent.ListLayout)

type Record = { [string]: unknown }
export type Entry = { context: Record, leading: Types.Node?, result: FlexScene.Result }
local FlexLayouts = {}

-- Contexts own scalar records (including length units and calculation bounds).
-- Unknown object inputs or metatables keep the ordinary formatter path.
local function copyRecord(source: Record, depth: number): Record?
	if getmetatable(source) ~= nil then
		return nil
	end
	local result: Record = {}
	for name, value in source do
		if type(value) == "table" then
			if depth >= 2 then
				return nil
			end
			local copy = copyRecord(value :: Record, depth + 1)
			if not copy then
				return nil
			end
			result[name] = copy
		elseif type(value) == "number" or type(value) == "boolean" or type(value) == "string" then
			result[name] = value
		else
			return nil
		end
	end
	return result
end

local function sameRecord(a: Record, b: Record): boolean
	if getmetatable(b) ~= nil then
		return false
	end
	for name, value in a do
		local other = b[name]
		if type(value) == "table" and type(other) == "table" then
			if not sameRecord(value :: Record, other :: Record) then
				return false
			end
		elseif value ~= other then
			return false
		elseif type(value) == "number" and value == 0 and type(other) == "number" and 1 / value ~= 1 / other then
			return false
		end
	end
	for name in b do
		if a[name] == nil then
			return false
		end
	end
	return true
end

local function copyUsed(items: { FlexTypes.UsedItem }): { FlexTypes.UsedItem }
	local result = {}
	for i, item in items do
		result[i] = table.clone(item)
	end
	return result
end

local function copyPlacement(plan: ListLayout.Plan): ListLayout.Plan
	local result = table.clone(plan)
	result.items = {}
	for i, item in plan.items do
		local copy = table.clone(item)
		if item.margins then
			copy.margins = table.clone(item.margins)
		end
		result.items[i] = copy
	end
	return result
end

local resultFields = { inputs = true, used = true, placement = true, height = true, lines = true }
local usedFields = { node = true, width = true, height = true, widthDefinite = true, heightDefinite = true }
local planFields = {
	width = true,
	height = true,
	horizontal = true,
	mainAlign = true,
	mainStart = true,
	crossAlign = true,
	gap = true,
	items = true,
	manual = true,
	crossStart = true,
}
local itemFields = { node = true, width = true, height = true, crossAlign = true, margins = true }
local marginFields = {
	left = true,
	right = true,
	top = true,
	bottom = true,
	autoLeft = true,
	autoRight = true,
	autoTop = true,
	autoBottom = true,
}
local lineFields = { used = true, placement = true, y = true }
local function known(source: Record, fields: { [string]: boolean }): boolean
	for name in source do
		if not fields[name] then
			return false
		end
	end
	return true
end
local function knownUsed(used: { FlexTypes.UsedItem }): boolean
	for _, item in used do
		if not known(item :: Record, usedFields) then
			return false
		end
	end
	return true
end
local function knownPlan(plan: ListLayout.Plan): boolean
	if not known(plan :: Record, planFields) then
		return false
	end
	for _, item in plan.items do
		if
			not known(item :: Record, itemFields)
			or item.margins and not known(item.margins :: Record, marginFields)
		then
			return false
		end
	end
	return true
end
local function copyResult(source: FlexScene.Result): FlexScene.Result?
	if not known(source :: Record, resultFields) or not knownUsed(source.used) or not knownPlan(source.placement) then
		return nil
	end
	local cost = #source.used + #source.placement.items
	for _, line in source.lines or {} do
		if not known(line :: Record, lineFields) or not knownUsed(line.used) or not knownPlan(line.placement) then
			return nil
		end
		cost += #line.used + #line.placement.items
	end
	if cost > 256 then
		return nil
	end
	local result: FlexScene.Result = {
		used = copyUsed(source.used),
		placement = copyPlacement(source.placement),
		height = source.height,
	}
	-- Sizing callbacks, old styles and metric inputs are deliberately omitted.
	-- The formatter reads current styles and resolves fresh child metrics.
	if source.lines then
		local lines = {}
		for i, line in source.lines do
			lines[i] = { used = copyUsed(line.used), placement = copyPlacement(line.placement), y = line.y }
		end
		result.lines = lines
	end
	return result
end

function FlexLayouts.find(entries: { Entry }, context: FlexTypes.Context, leading: Types.Node?): FlexScene.Result?
	for _, entry in entries do
		if entry.leading == leading and sameRecord(entry.context, context :: Record) then
			return copyResult(entry.result)
		end
	end
	return nil
end

function FlexLayouts.capture(
	entries: { Entry },
	context: FlexTypes.Context,
	leading: Types.Node?,
	result: FlexScene.Result
)
	local inputs = copyRecord(context :: Record, 0)
	if not inputs then
		return
	end
	local copy = copyResult(result)
	if not copy then
		return
	end
	if #entries == 4 then
		table.remove(entries, 1)
	end
	table.insert(entries, { context = inputs, leading = leading, result = copy })
end

return FlexLayouts
