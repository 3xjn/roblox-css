--!strict

local Types = require(script.Parent.Types)

export type Style = Types.InlineStyle
local InlineStyle = {}

local function dense(value: { any })
	local count = 0
	for key in value do
		assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= #value, "Inline CSS requires ordered arrays")
		count += 1
	end
	assert(count == #value, "Inline CSS requires dense arrays")
end

local function tokens(source: { Types.ValueToken }, active: { [any]: boolean }): { Types.ValueToken }
	assert(not active[source], "Inline CSS tokens contain a cycle")
	active[source] = true
	dense(source)
	local result = {}
	for _, token in source do
		assert(type(token.kind) == "string" and type(token.value) == "string", "Invalid inline CSS token")
		local copy = table.clone(token)
		copy.color = if token.color then table.clone(token.color) else nil
		copy.children = if token.children then tokens(token.children, active) else nil
		table.insert(result, copy)
	end
	active[source] = nil
	return result
end

local function sameTokens(a: { Types.ValueToken }?, b: { Types.ValueToken }?): boolean
	if a == b then return true end
	if not a or not b or #a ~= #b then return false end
	for i, token in a do
		local other = b[i]
		if token.kind ~= other.kind or token.value ~= other.value or token.unit ~= other.unit
			or token.quote ~= other.quote or token.syntaxType ~= other.syntaxType
		then return false end
		local x, y = token.color, other.color
		if x ~= y and (not x or not y or x.r ~= y.r or x.g ~= y.g or x.b ~= y.b or x.alpha ~= y.alpha) then
			return false
		end
		if not sameTokens(token.children, other.children) then return false end
	end
	return true
end

function InlineStyle.sameMetadata(a: Types.PropertyMetadata, b: Types.PropertyMetadata, allowMissingAnimationType: boolean?): boolean
	if a == b then return true end
	if a.inherited ~= b.inherited or a.initialText ~= b.initialText or not sameTokens(a.initial, b.initial) then return false end
	local animationA, animationB = a.animationType, b.animationType
	if animationA ~= animationB and not (allowMissingAnimationType and (animationA == nil or animationB == nil)) then
		if type(animationA) ~= "table" or type(animationB) ~= "table" or #animationA ~= #animationB then return false end
		for i, value in animationA do if animationB[i] ~= value then return false end end
	end
	local x, y = a.longhands, b.longhands
	if x == y then return true end
	if not x or not y or #x ~= #y then return false end
	for i, name in x do if y[i] ~= name then return false end end
	return true
end

-- The same normalized declaration IR as the compiler. No CSS parser or
-- JavaScript-style value/unit guessing is shipped to the client.
function InlineStyle.copy(source: Style?): Style?
	if not source then return nil end
	dense(source.declarations)
	local declarations: { Types.Declaration } = {}
	for _, declaration in source.declarations do
		assert(declaration.kind == "declaration" and type(declaration.property) == "string"
			and declaration.property ~= "" and type(declaration.value) == "string"
			and type(declaration.important) == "boolean", "Invalid inline CSS declaration")
		local property = declaration.property
		if property:sub(1, 2) ~= "--" then property = string.lower(property) end
		local copy: Types.Declaration = {
			kind = "declaration", property = property, value = declaration.value,
			tokens = tokens(declaration.tokens, {}), important = declaration.important,
			validity = declaration.validity,
			source = if declaration.source then table.clone(declaration.source) else nil,
		}
		table.insert(declarations, copy)
	end
	local properties: { [string]: Types.PropertyMetadata }? = nil
	if source.properties then
		properties = {}
		for name, info in source.properties do
			assert(type(name) == "string" and type(info.inherited) == "boolean", "Invalid inline CSS property metadata")
			if info.longhands then dense(info.longhands) end
			if type(info.animationType) == "table" then dense(info.animationType) end
			properties[name] = {
				inherited = info.inherited, initialText = info.initialText,
				initial = if info.initial then tokens(info.initial, {}) else nil,
				longhands = if info.longhands then table.clone(info.longhands) else nil,
				animationType = if type(info.animationType) == "table" then table.clone(info.animationType) else info.animationType,
			}
		end
	end
	return { declarations = declarations, properties = properties }
end

function InlineStyle.equal(a: Style?, b: Style?): boolean
	if a == b then return true end
	if not a or not b or #a.declarations ~= #b.declarations then return false end
	for i, declaration in a.declarations do
		local other = b.declarations[i]
		if declaration.property ~= other.property or declaration.important ~= other.important
			or declaration.validity ~= other.validity or not sameTokens(declaration.tokens, other.tokens)
		then return false end
	end
	if a.properties ~= b.properties then
		for name, info in a.properties or {} do
			local other = if b.properties then b.properties[name] else nil
			if not other or not InlineStyle.sameMetadata(info, other) then return false end
		end
		for name in b.properties or {} do
			if not a.properties or not a.properties[name] then return false end
		end
	end
	return true
end

-- A finite CSSOM sizing grammar. This is not a general CSS parser: complex
-- functions/escapes and other properties require a parser capability and fail
-- before mutation. Existing prepared declarations remain readable/removable.
InlineStyle.mutableProperties = table.freeze({
	"height", "width", "min-height", "min-width", "max-height", "max-width",
	"justify-content", "align-content", "justify-items", "align-items",
})
local sizing = { height = "auto", width = "auto", ["min-height"] = "auto", ["min-width"] = "auto", ["max-height"] = "none", ["max-width"] = "none" }
local alignment = { ["justify-content"] = true, ["align-content"] = true, ["justify-items"] = true, ["align-items"] = true }
local alignmentKeywords = { normal=true, stretch=true, center=true, start=true, ["end"]=true,
	["flex-start"]=true, ["flex-end"]=true, baseline=true }
local contentKeywords = { ["space-between"]=true, ["space-around"]=true, ["space-evenly"]=true }
local itemKeywords = { ["self-start"]=true, ["self-end"]=true }
local units = { px=true, cm=true, mm=true, q=true, ["in"]=true, pt=true, pc=true, em=true, rem=true, lh=true, rlh=true,
	vw=true, vh=true, vmin=true, vmax=true }
local globalKeywords = { inherit=true, initial=true, unset=true, revert=true, ["revert-layer"]=true }
local function propertyName(name: string): string return if name:sub(1,2)=="--" then name else string.lower(name) end
function InlineStyle.getProperty(style: Style?, name: string): (string, string)
	local selected: Types.Declaration? = nil
	name = propertyName(name)
	for _, declaration in if style then style.declarations else {} do
		if declaration.property == name and (not selected or declaration.important or not selected.important) then selected = declaration end
	end
	return if selected then selected.value else "", if selected and selected.important then "important" else ""
end
local function sizingValue(name: string, source: string): (Types.ValueToken?, string?, string?)
	local text = source:match("^[ \t\r\n\f]*(.-)[ \t\r\n\f]*$") or source
	local lower = string.lower(text)
	if alignment[name] then
		local extra = if name == "justify-content" or name == "align-content" then contentKeywords else itemKeywords
		if globalKeywords[lower] or alignmentKeywords[lower] or extra[lower] then return {kind="word",value=lower},lower,nil end
		return nil,nil,"inline-style-value-parser-required:"..name
	end
	if not sizing[name] then return nil,nil,"inline-style-property-parser-required:"..name end
	if lower == sizing[name] or globalKeywords[lower] then return {kind="word",value=lower},lower,nil end
	local position, length, digits = 1,#text,0
	if text:sub(position,position)=="+" or text:sub(position,position)=="-" then position+=1 end
	while text:sub(position,position):match("%d") do position+=1;digits+=1 end
	if text:sub(position,position)=="." and text:sub(position+1,position+1):match("%d") then
		position+=1
		while text:sub(position,position):match("%d") do position+=1;digits+=1 end
	end
	if digits==0 then return nil,nil,"inline-style-value-parser-required:"..name end
	if text:sub(position,position):lower()=="e" then
		local at = position+1
		if text:sub(at,at)=="+" or text:sub(at,at)=="-" then at+=1 end
		local first = at
		while text:sub(at,at):match("%d") do at+=1 end
		if at>first then position=at end
	end
	local numberText = text:sub(1,position-1)
	local value, unit = tonumber(numberText), string.lower(text:sub(position,length))
	if not value or value~=value or math.abs(value)==math.huge or value<0 then return nil,nil,"inline-style-value-parser-required:"..name end
	if unit=="" and value==0 then unit="px" end
	if unit~="%" and not units[unit] then return nil,nil,"inline-style-value-parser-required:"..name end
	local serialized = string.gsub(string.gsub(string.format("%.6f",value),"0+$",""),"%.$","")
	if serialized=="-0" then serialized="0" end
	if unit=="%" then return {kind="percentage",value=serialized},serialized.."%",nil end
	return {kind="dimension",value=serialized,unit=unit},serialized..unit,nil
end
function InlineStyle.setProperty(style: Style?, name: string, value: string, priority: string?): (Style?, string?)
	name=propertyName(name)
	local important = priority~=nil and string.lower(priority)=="important"
	if value~="" and priority~=nil and priority~="" and not important then return InlineStyle.copy(style) or {declarations={}},nil end
	local declaration: Types.Declaration? = nil
	if value~="" then
		local token, serialized, failure = sizingValue(name,value)
		if not token or not serialized then return nil,failure end
		local prepared: Types.Declaration = {kind="declaration",property=name,value=serialized,tokens={token},important=important,validity="valid"}
		declaration=prepared
	end
	local result: Style=InlineStyle.copy(style) or {declarations={},properties=nil}
	local declarations: {Types.Declaration} = {}
	local inserted=false
	for _, previous in result.declarations do
		if previous.property==name then
			if declaration and not inserted then table.insert(declarations,declaration);inserted=true end
		else table.insert(declarations,previous) end
	end
	if declaration and not inserted then table.insert(declarations,declaration) end
	result.declarations=declarations
	return result,nil
end

return InlineStyle
