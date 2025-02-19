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
		previous_ids: jecs.Query<>,
	},
	_Previous: jecs.Entity<jecs.Entity>,
	world: jecs.World,
	Networked: jecs.Entity<{ Player }?>,
	hydrate: (self: Mirror, player: Player) -> Changes,
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

local function ref_server(self: Mirror, id: number): (jecs.Entity, () -> ())
	if not self._entities[id] then
		self._entities[id] = self.world:entity()
	end

	local function drop()
		self._entities[id] = nil
	end

	return self._entities[id], drop
end

local function hydrate(self: Mirror, player: Player): Changes
	local all_changes = {} :: Changes

	for component, name in self._queries.networked_component_names:iter() do
		for id, value, players in self.world:query(component, self.Networked):without(jecs.Component):iter() do
			local is_allowed = players == nil or table.find(players, player) ~= nil
			if is_allowed then
				all_changes[id] = all_changes[id] or {}
				all_changes[id][name] = if value == nil then NOTHING else value
			end
		end
	end

	return all_changes
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

	for id in self._queries.previous_ids:iter() do
		local component = self.world:target(id, self._Previous)
		local name = self.world:get(component, jecs.Name) :: string
		if not self.world:has(id, component) then
			full_changes[id] = full_changes[id] or {}
			full_changes[id][name] = DELETED
		end
	end

	for _, id in self._deleted do
		full_changes[id] = DELETED
	end
	table.clear(self._deleted)

	local filtered_changes = {} :: { [Player]: Changes }
	local all_players = Players:GetPlayers()

	for id, changes in full_changes do
		local players = self.world:get(id, self.Networked) or all_players
		for _, player in players do
			filtered_changes[player] = filtered_changes[player] or {}
			filtered_changes[player][id] = changes
		end
	end

	return filtered_changes
end

local function apply(self: Mirror, full_changes: Changes)
	for server_id, changes in full_changes do
		local id, delete = ref_server(self, server_id)
		if changes == DELETED then
			delete()
			self.world:delete(id)
			continue
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

	local deleted = {}
	world:set(Networked, jecs.OnRemove, function(id)
		if not world:has(id, jecs.Component) then
			table.insert(deleted, id)
		end
	end)

	return {
		_entities = {},
		_deleted = deleted,
		_queries = {
			networked_component_names = world:query(jecs.Name):with(jecs.Component, Networked):cached(),
			previous_ids = world:query(pair(Previous, jecs.Wildcard)):cached(),
		},
		_Previous = Previous,
		world = world,
		Networked = Networked,
		hydrate = hydrate,
		collect = collect,
		apply = apply,
	}
end

return { new = new }
