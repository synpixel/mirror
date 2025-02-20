local Players = game:GetService("Players")
local jecs = require(script.roblox_packages.jecs)

type Deleted = "__d"
type Nothing = "__n"
type Changed<T> = Deleted | Nothing | T
export type Changes = { [number]: Changed<{ [string]: Changed<any> }> }

local DELETED: Deleted = "__d"
local NOTHING: Nothing = "__n"

export type Mirror = {
	_entities: { [number]: jecs.Entity },
	_deleted: { jecs.Entity },
	_queries: {
		networked_component_names: jecs.Query<string>,
		previous: jecs.Query<>,
	},
	_Previous: jecs.Entity<jecs.Entity>,
	world: jecs.World,
	Networked: jecs.Entity<{ Player }?>,
	collect: (self: Mirror) -> { [Player]: Changes },
	apply: (self: Mirror, changes: Changes) -> (),
}

local pair = jecs.pair

local function eq(a: any, b: any): boolean
	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return a == b
	end

	for k, v in a do
		if not eq(v, b[k]) then
			return false
		end
	end

	for k, v in b do
		if not eq(v, a[k]) then
			return false
		end
	end

	return true
end

local function find_component(self: Mirror, target_name: string): jecs.Entity?
	for component, name in self._queries.networked_component_names:iter() do
		if name == target_name then
			return component
		end
	end
	return nil
end

local function collect(self: Mirror): { [Player]: Changes }
	local full_changes = {} :: Changes

	for component, name in self._queries.networked_component_names:iter() do
		for id, value in self.world:query(component):without(jecs.Component):with(self.Networked):iter() do
			local previous = self.world:get(id, pair(self._Previous, component))
			if not eq(previous, value) then
				full_changes[id] = full_changes[id] or {}
				full_changes[id][name] = if value == nil then NOTHING else value
				self.world:set(id, pair(self._Previous, component), value)
			end
		end
	end

	for id in self._queries.previous:iter() do
		local component = self.world:target(id, self._Previous)
		local name = self.world:get(component, jecs.Name) :: string
		if not self.world:has(id, component) then
			full_changes[id] = full_changes[id] or {}
			full_changes[id][name] = DELETED
			self.world:remove(id, pair(self._Previous, component))
		end
	end

	for _, id in self._deleted do
		full_changes[id] = DELETED
	end
	table.clear(self._deleted)

	local filtered_changes = {} :: { [Player]: Changes }
	local all_players = Players:GetPlayers()

	for id, changes in full_changes do
		local players = self.world:get(id, self.Networked)
		local previous_players = self.world:get(id, pair(self._Previous, self.Networked))

		for _, player in all_players do
			local is_allowed = players == nil or table.find(players, player) ~= nil
			local was_allowed = previous_players == nil or table.find(previous_players, player) ~= nil

			if is_allowed and was_allowed then
				filtered_changes[player] = filtered_changes[player] or {}
				filtered_changes[player][id] = changes
			elseif is_allowed then
				filtered_changes[player] = filtered_changes[player] or {}

				for component, name in self._queries.networked_component_names:iter() do
					local value = self.world:get(id, component)
					filtered_changes[player][id] = filtered_changes[player][id] or {}
					filtered_changes[player][id][name] = if value == nil then NOTHING else value
				end
			elseif was_allowed then
				filtered_changes[player] = filtered_changes[player] or {}
				filtered_changes[player][id] = DELETED
			end
		end

		if players ~= previous_players then
			self.world:set(id, pair(self._Previous, self.Networked), players)
		end
	end

	return filtered_changes
end

local function apply(self: Mirror, full_changes: Changes)
	for server_id, changes in full_changes do
		local id = self._entities[server_id]

		if changes == DELETED then
			if id then
				self.world:delete(id)
				self._entities[server_id] = nil
			end
			continue
		end

		if not id then
			id = self.world:entity()
			self._entities[server_id] = id
		end

		assert(typeof(changes) == "table", "luau")

		for name, value in changes do
			local component = assert(find_component(self, name), `failed to find component "{name}"`)
			if value == DELETED then
				self.world:remove(id, component)
				continue
			end

			self.world:set(id, component, if value == NOTHING then nil else value)
		end
	end
end

local function new(world: jecs.World): Mirror
	local Networked = world:component() :: jecs.Entity<{ Player }?>
	local Previous = world:entity()

	local mirror = {
		_entities = {},
		_deleted = {},
		_queries = {
			networked_component_names = world:query(jecs.Name):with(jecs.Component, Networked):cached(),
			previous = world:query(pair(Previous, jecs.Wildcard)):cached(),
		},
		_Previous = Previous,
		world = world,
		Networked = Networked,
		collect = collect,
		apply = apply,
	}

	world:set(Networked, jecs.OnRemove, function(id)
		if not world:has(id, jecs.Component) then
			table.insert(mirror._deleted, id)
		end
	end)

	return mirror
end

return { new = new }
