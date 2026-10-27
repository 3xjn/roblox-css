--!strict

local Values = require(script.Parent.NativeValueTransition)
export type Controller = Values.Controller<number>
local operations: Values.Operations<number> = table.freeze({
	equal = function(a: number, b: number): boolean
		return a == b
	end,
	interpolate = function(a: number, b: number, progress: number): number
		return a + (b - a) * progress
	end,
})

local function create(parent: Instance, name: string, paint: (number) -> (), settled: () -> ()): Controller
	return Values.create(parent, name, operations, paint, settled)
end

return { create = create }
