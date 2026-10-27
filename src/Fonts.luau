--!strict

local Types = require(script.Parent.Types)
local Typography = require(script.Parent.Typography)

export type Input = Font | Enum.Font
export type FeatureDefaults = { [string]: number }
export type RegistrationOptions = { defaultFeatures: FeatureDefaults? }
export type Face = {
	font: Font,
	weight: number?,
	style: string?,
	metrics: Typography.Metrics?,
	defaultFeatures: FeatureDefaults?,
}
export type Resolved = {
	font: Font,
	family: string,
	weight: number,
	style: string,
	metrics: Typography.Metrics?,
	substitutedStyle: boolean,
	defaultFeatures: FeatureDefaults?,
}
type Family = {
	font: Font?,
	faces: { Face }?,
	metrics: Typography.Metrics?,
	defaultFeatures: FeatureDefaults?,
	active: boolean,
	previous: Family?,
	next: Family?,
}

local Fonts = {}
Fonts.__index = Fonts
local nativeWeights = table.freeze(Enum.FontWeight:GetEnumItems())

local function copyMetrics(metrics: Typography.Metrics?): Typography.Metrics?
	return if metrics then table.clone(metrics) else nil
end

-- Registration owns this immutable declaration. It describes feature values
-- already satisfied by the supplied face; it does not substitute a font.
local function copyDefaults(defaults: FeatureDefaults?): FeatureDefaults?
	if defaults == nil then
		return nil
	end
	assert(type(defaults) == "table", "Font feature defaults must be a table")
	local result: FeatureDefaults = {}
	for tag, value in defaults do
		assert(type(tag) == "string" and #tag == 4 and not tag:find("[^ -~]"), "Invalid default OpenType tag")
		assert(
			type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0,
			"Font feature defaults require finite nonnegative integers"
		)
		result[tag] = value
	end
	return table.freeze(result)
end

local function native(input: Input): Font
	if typeof(input) == "Font" then
		local font = input :: Font
		return Font.new(font.Family, font.Weight, font.Style)
	end
	assert(input ~= Enum.Font.Unknown, "Enum.Font.Unknown is not a font family")
	return Font.fromEnum(input :: Enum.Font)
end

local function name(value: string): string
	return string.lower(value:match("^%s*(.-)%s*$") or value)
end

local function families(tokens: { Types.ValueToken }?): ({ string }?, string?)
	if not tokens then
		return { "sans-serif" }, nil
	end
	if #tokens == 1 and (tokens[1].kind == "word" or tokens[1].kind == "string") then
		return { name(tokens[1].value) }, nil
	end
	local result = {}
	local parts: { string } = {}
	local quoted = false
	for _, token in tokens do
		if token.kind == "div" and token.value == "," then
			if #parts == 0 then
				return nil, "empty-font-family"
			end
			table.insert(result, name(table.concat(parts, " ")))
			table.clear(parts)
			quoted = false
		elseif token.kind == "string" then
			if #parts > 0 then
				return nil, "invalid-quoted-font-family"
			end
			table.insert(parts, token.value)
			quoted = true
		elseif token.kind == "word" then
			if quoted then
				return nil, "invalid-font-family-list"
			end
			table.insert(parts, token.value)
		elseif token.kind ~= "space" and token.kind ~= "comment" then
			return nil, `unsupported-font-family-token:{token.kind}`
		end
	end
	if #parts == 0 then
		return nil, "empty-font-family"
	end
	table.insert(result, name(table.concat(parts, " ")))
	return result, nil
end

-- CSS Fonts 4 font matching, including its 400..500 search direction.
local function preference(weight: number, desired: number): (number, number)
	if desired >= 400 and desired <= 500 then
		if weight >= desired and weight <= 500 then
			return 1, weight
		end
		if weight < desired then
			return 2, -weight
		end
		return 3, weight
	elseif desired < 400 then
		return if weight <= desired then 1 else 2, if weight <= desired then -weight else weight
	end
	return if weight >= desired then 1 else 2, if weight >= desired then weight else -weight
end

local function better(weight: number, previous: number, desired: number): boolean
	local group, order = preference(weight, desired)
	local previousGroup, previousOrder = preference(previous, desired)
	return group < previousGroup or (group == previousGroup and order < previousOrder)
end

local function emit(self: Provider)
	for listener in table.clone(self._listeners) do
		if self._listeners[listener] then
			listener()
		end
	end
end

function Fonts.new(): Provider
	local self =
		setmetatable({ _families = {} :: { [string]: Family }, _listeners = {} :: { [() -> ()]: boolean } }, Fonts)
	-- Native defaults are configurable and are not a claim of browser font parity.
	local sans = Font.fromEnum(Enum.Font.BuilderSans)
	for _, alias in { "sans-serif", "ui-sans-serif", "system-ui" } do
		self._families[alias] = { font = sans, active = true }
	end
	local mono = Font.fromEnum(Enum.Font.Code)
	self._families.monospace = { font = mono, active = true }
	self._families["ui-monospace"] = { font = mono, active = true }
	return self
end

local function disposer(self: Provider, key: string, registration: Family): () -> ()
	return function()
		if not registration.active then
			return
		end
		registration.active = false
		local previous = registration.previous
		local following = registration.next
		if following then
			following.previous = previous
		end
		if previous then
			previous.next = following
		end
		registration.previous = nil
		registration.next = nil
		if self._families[key] == registration then
			self._families[key] = previous
			emit(self)
		end
	end
end

function Fonts.register(
	self: Provider,
	family: string,
	input: Input,
	metrics: Typography.Metrics?,
	options: RegistrationOptions?
): () -> ()
	assert(options == nil or type(options) == "table", "Font registration options must be a table")
	local key = name(family)
	assert(key ~= "", "A font family needs a name")
	local previous = self._families[key]
	local registration: Family = {
		font = native(input),
		metrics = if metrics then table.clone(metrics) else nil,
		defaultFeatures = copyDefaults(if options then options.defaultFeatures else nil),
		active = true,
		previous = previous,
	}
	if previous then
		previous.next = registration
	end
	self._families[key] = registration
	emit(self)
	return disposer(self, key, registration)
end

function Fonts.registerFaces(self: Provider, family: string, faces: { Face }): () -> ()
	assert(#faces > 0, "A font family needs at least one face")
	local key = name(family)
	assert(key ~= "", "A font family needs a name")
	local copies: { Face } = {}
	for _, face in faces do
		local weight = face.weight or face.font.Weight.Value
		local style = face.style or string.lower(face.font.Style.Name)
		assert(weight >= 1 and weight <= 1000, "CSS font weights must be in 1..1000")
		assert(style == "normal" or style == "italic", "Only normal and italic faces are implemented")
		table.insert(copies, {
			font = native(face.font),
			weight = weight,
			style = style,
			metrics = if face.metrics then table.clone(face.metrics) else nil,
			defaultFeatures = copyDefaults(face.defaultFeatures),
		})
	end
	local previous = self._families[key]
	local registration: Family = { faces = copies, active = true, previous = previous }
	if previous then
		previous.next = registration
	end
	self._families[key] = registration
	emit(self)
	return disposer(self, key, registration)
end

-- Match registration metadata first. Metrics queries do not need a native Font
-- or a copied Resolved record; actual glyph resolution constructs those later.
local function match(
	self: Provider,
	tokens: { Types.ValueToken }?,
	weight: number,
	style: string
): (Family?, Face?, string?, string?, string?)
	if weight ~= weight or weight < 1 or weight > 1000 then
		return nil, nil, nil, nil, "invalid-font-weight"
	end
	style = string.lower(style)
	if style ~= "normal" and style ~= "italic" then
		return nil, nil, nil, nil, `unsupported-font-style:{style}`
	end
	local names, failure = families(tokens)
	if not names then
		return nil, nil, nil, nil, failure
	end
	for _, key in names do
		local family = self._families[key]
		if not family then
			continue
		end
		if family.font then
			return family, nil, key, style, nil
		end
		local faces = family.faces or {}
		local selected: Face? = nil
		for _, face in faces do
			if not selected then
				selected = face
				continue
			end
			local sameStyle = face.style == style
			local previousSameStyle = selected.style == style
			if
				(sameStyle and not previousSameStyle)
				or (sameStyle == previousSameStyle and better(face.weight or 400, selected.weight or 400, weight))
			then
				selected = face
			end
		end
		if selected then
			return family, selected, key, style, nil
		end
	end
	return nil, nil, nil, nil, "no-registered-font-family"
end

function Fonts.resolve(
	self: Provider,
	tokens: { Types.ValueToken }?,
	weight: number,
	style: string
): (Resolved?, string?)
	local family, face, key, requestedStyle, failure = match(self, tokens, weight, style)
	if not family then
		return nil, failure
	end
	if face then
		return {
			font = native(face.font),
			family = assert(key),
			weight = face.weight or 400,
			style = face.style or "normal",
			metrics = copyMetrics(face.metrics),
			substitutedStyle = face.style ~= requestedStyle,
			defaultFeatures = face.defaultFeatures,
		},
			nil
	end
	local selected = Enum.FontWeight.Regular
	for _, candidate in nativeWeights do
		if better(candidate.Value, selected.Value, weight) then
			selected = candidate
		end
	end
	return {
		font = Font.new(
			assert(family.font).Family,
			selected,
			if requestedStyle == "italic" then Enum.FontStyle.Italic else Enum.FontStyle.Normal
		),
		family = assert(key),
		weight = selected.Value,
		style = assert(requestedStyle),
		metrics = copyMetrics(family.metrics),
		substitutedStyle = false,
		defaultFeatures = family.defaultFeatures,
	},
		nil
end

local function styleRequest(style: Types.ComputedStyle): (number?, string?, string?)
	for _, property in { "font-family", "font-weight", "font-style" } do
		if style.unresolved[property] then
			return nil, nil, style.unresolved[property]
		end
	end
	local properties = style.properties
	local weight = 400
	local weightTokens = properties["font-weight"]
	if weightTokens then
		if #weightTokens ~= 1 or weightTokens[1].kind ~= "number" then
			return nil, nil, "computed-font-weight-required"
		end
		weight = tonumber(weightTokens[1].value) or 0
	end
	local slant = properties["font-style"]
	if slant and (#slant ~= 1 or slant[1].kind ~= "word") then
		return nil, nil, "computed-font-style-required"
	end
	return weight, if slant then slant[1].value else "normal", nil
end

function Fonts.resolveStyle(self: Provider, style: Types.ComputedStyle): (Resolved?, string?)
	local weight, slant, failure = styleRequest(style)
	if weight == nil then
		return nil, failure
	end
	return self:resolve(style.properties["font-family"], weight, assert(slant))
end

function Fonts.getMetrics(self: Provider, style: Types.ComputedStyle): Typography.Metrics?
	-- Preserve caller-supplied method overrides and their matching semantics.
	local resolveStyle = self.resolveStyle
	local resolve = self.resolve
	if resolveStyle ~= Fonts.resolveStyle or resolve ~= Fonts.resolve then
		local resolved = resolveStyle(self, style)
		return if resolved and not resolved.substitutedStyle then copyMetrics(resolved.metrics) else nil
	end
	local weight, slant = styleRequest(style)
	if weight == nil then
		return nil
	end
	local family, face, _, requestedStyle = match(self, style.properties["font-family"], weight, assert(slant))
	if not family or (face and face.style ~= requestedStyle) then
		return nil
	end
	return copyMetrics(if face then face.metrics else family.metrics)
end

function Fonts.subscribe(self: Provider, listener: () -> ()): () -> ()
	self._listeners[listener] = true
	return function()
		self._listeners[listener] = nil
	end
end

export type Provider = typeof(setmetatable(
	{} :: {
		_families: { [string]: Family },
		_listeners: { [() -> ()]: boolean },
	},
	Fonts
))

return {
	create = Fonts.new,
	-- Overrides may read style inputs beyond the built-in font properties.
	hasDefaultMetrics = function(provider: Provider): boolean
		return provider.getMetrics == Fonts.getMetrics
			and provider.resolveStyle == Fonts.resolveStyle
			and provider.resolve == Fonts.resolve
	end,
}
