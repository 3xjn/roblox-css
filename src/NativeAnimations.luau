--!strict

local Programs = require(script.Parent.SceneAnimations)
local Animations = require(script.Parent.Animations)
local Clock = require(script.Parent.NativeAnimationClock)
local Values = require(script.Parent.AnimationValues)
local Playback = require(script.Parent.Playback)
type Entry = { program: Programs.Effect, clock: Clock.Clock }
local NativeAnimations = {}
NativeAnimations.__index = NativeAnimations

local function match(old: { Entry }, effects: { Programs.Effect }): { [number]: Entry }
	local used: { [number]: boolean } = {}
	local result: { [number]: Entry } = {}
	for index = #effects, 1, -1 do
		for previous = #old, 1, -1 do
			if not used[previous] and old[previous].program.config.name == effects[index].config.name then
				result[index] = old[previous]
				used[previous] = true
				break
			end
		end
	end
	return result
end

function NativeAnimations.times(self: Controller, effects: { Programs.Effect }): { number }
	local matched = match(self._entries, effects)
	local result = {}
	for index in effects do
		result[index] = if matched[index] then matched[index].clock:current() else 0
	end
	return result
end

function NativeAnimations.playbacks(self: Controller): { Playback.Handle }
	local result = {}
	if not self._destroyed then
		for _, entry in self._entries do
			local handle = entry.clock:playback()
			if handle then
				table.insert(result, handle)
			end
		end
	end
	return result
end

-- A style query samples the same effect stack as painting, on demand. The
-- boolean distinguishes an active contribution from the underlying value:
-- an unfilled effect must not manufacture rotate(0) for transform:none.
function NativeAnimations.current(self: Controller, property: string): (Values.Value?, boolean)
	local data = self._data
	if self._destroyed or not data then
		return nil, false
	end
	local value, contributed = data.bases[property], false
	for _, entry in self._entries do
		local track = entry.program.tracks[property]
		if not track then
			continue
		end
		local state, why = Animations.sample(entry.program.config, entry.clock:current())
		assert(state, why)
		if state.progress == nil then
			continue
		end
		local interval, failure = Animations.interval(track.source, state.progress, state.before)
		assert(interval, failure)
		local endpoints = assert(track.values, "unprepared-native-animation-track")
		local a = if interval.start.underlying then value else endpoints[interval.start]
		local b = if interval.finish.underlying then value else endpoints[interval.finish]
		local nextValue, reason = Values.interpolate(a, b, interval.progress)
		assert(nextValue ~= nil, reason)
		value, contributed = nextValue, true
	end
	return value, contributed
end

function NativeAnimations._render(self: Controller)
	local data = self._data
	if self._destroyed or not data then
		return
	end
	local values = table.clone(data.bases)
	local rotationNeeded, translationNeeded, scaleNeeded, opacityNeeded = false, false, false, false
	for _, entry in self._entries do
		local program = entry.program
		local state, why = Animations.sample(program.config, entry.clock:current())
		assert(state, why)
		local needed = state.phase ~= "after" or state.progress ~= nil
		if needed then
			rotationNeeded = rotationNeeded or program.tracks.transform ~= nil or program.tracks.rotate ~= nil
			translationNeeded = translationNeeded or program.tracks.translate ~= nil
			scaleNeeded = scaleNeeded or program.tracks.scale ~= nil
			opacityNeeded = opacityNeeded or program.tracks.opacity ~= nil
		end
		if state.progress == nil then
			continue
		end
		for property, track in program.tracks do
			local interval, failure = Animations.interval(track.source, state.progress, state.before)
			assert(interval, failure)
			local endpoints = assert(track.values, "unprepared-native-animation-track")
			local a = if interval.start.underlying then values[property] else endpoints[interval.start]
			local b = if interval.finish.underlying then values[property] else endpoints[interval.finish]
			local value, reason = Values.interpolate(a, b, interval.progress)
			assert(value ~= nil, reason)
			values[property] = value
		end
	end
	self._paint(values)
	if
		not self._settleRequested
		and (
			rotationNeeded ~= data.rotationNeeded
			or translationNeeded ~= data.translationNeeded
			or scaleNeeded ~= data.scaleNeeded
			or opacityNeeded ~= data.opacityNeeded
		)
	then
		self._settleRequested = true
		self._settled()
	end
end

function NativeAnimations.paint(self: Controller)
	local ok, failure = pcall(self._render, self)
	if not ok then
		self:destroy()
		self._diagnose("native-animation-paint:" .. tostring(failure))
	end
end
function NativeAnimations._schedule(self: Controller)
	if self._destroyed or self._syncing or self._pending then
		return
	end
	self._pending = task.defer(function()
		self._pending = nil
		if not self._destroyed then
			self:paint()
		end
	end)
end
function NativeAnimations.new(parent: Instance, settled: () -> (), diagnose: (string) -> ()): Controller
	return setmetatable({
		_parent = parent,
		_settled = settled,
		_diagnose = diagnose,
		_data = nil :: Programs.Data?,
		_entries = {} :: { Entry },
		_paint = function(_values: { [string]: Values.Value }) end,
		_pending = nil :: thread?,
		_destroyed = false,
		_syncing = false,
		_settleRequested = false,
	}, NativeAnimations)
end
function NativeAnimations.update(self: Controller, data: Programs.Data, paint: ({ [string]: Values.Value }) -> ())
	self._syncing = true
	self._settleRequested = false
	local matched = match(self._entries, data.effects)
	local entries: { Entry } = {}
	local retained: { [Entry]: boolean } = {}
	for index, program in data.effects do
		local entry = matched[index]
		if not entry then
			entry = { program = program, clock = Clock.new(self._parent, function()
				self:_schedule()
			end) }
		end
		entry.program = program
		entries[index] = entry
		retained[entry] = true
	end
	for _, entry in self._entries do
		if not retained[entry] then
			entry.clock:destroy()
		end
	end
	self._entries, self._data, self._paint = entries, data, paint
	for _, entry in entries do
		local enabled = next(entry.program.tracks) ~= nil
		local ok, why = entry.clock:update(entry.program.config, enabled)
		assert(ok, why)
	end
	self._syncing = false
	self:paint()
end
function NativeAnimations.destroy(self: Controller)
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self._pending then
		task.cancel(self._pending)
		self._pending = nil
	end
	for _, entry in self._entries do
		entry.clock:destroy()
	end
	table.clear(self._entries)
	self._data = nil
	self._paint = function() end
	self._settled = function() end
end
export type Controller = typeof(setmetatable(
	{} :: {
		_parent: Instance,
		_entries: { Entry },
		_data: Programs.Data?,
		_paint: ({ [string]: Values.Value }) -> (),
		_settled: () -> (),
		_diagnose: (string) -> (),
		_pending: thread?,
		_destroyed: boolean,
		_syncing: boolean,
		_settleRequested: boolean,
	},
	NativeAnimations
))
return NativeAnimations
