local Players = game:GetService("Players")
local jecs = require(script.Parent.roblox_packages.jecs)

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
	_awaiting_hydration: { Player },
	_Previous: jecs.Entity<jecs.Entity>,
	world: jecs.World,
	Networked: jecs.Entity<{ Player }?>,
	collect: (self: Mirror) -> { [Player]: Changes },
	apply: (self: Mirror, changes: Changes) -> (),
}

local pair = jecs.pair

local function get_targets(world: jecs.World, entity: jecs.Entity, relation: jecs.Entity): { [number]: jecs.Entity }
	local targets = {}
	local nth = 0

	while true do
		local target = world:target(entity, relation, nth)
		if not target then
			return targets
		end

		targets[nth] = target
		nth += 1
	end
end

local function find_component(self: Mirror, target_name: string): jecs.Entity?
	for component, name in self._queries.networked_component_names:iter() do
		if name == target_name then
			return component
		end
	end
	return nil
end

local function hydrate(self: Mirror, player: Player): Changes
	local hydration = {} :: Changes

	for component, name in self._queries.networked_component_names:iter() do
		for id, value in self.world:query(component):without(jecs.Component):with(self.Networked):iter() do
			local players = self.world:get(id, self.Networked)
			local scoped_players = self.world:get(id, pair(self.Networked, component))
			local is_allowed = (players == nil or table.find(players, player) ~= nil)
				and (scoped_players == nil or table.find(scoped_players, player) ~= nil)

			if is_allowed then
				hydration[id] = hydration[id] or {}
				hydration[id][name] = if value == nil then NOTHING else value
			end
		end
	end

	return hydration
end

local function collect(self: Mirror): { [Player]: Changes }
	local full_changes = {} :: Changes

	for component, name in self._queries.networked_component_names:iter() do
		for id, value in self.world:query(component):without(jecs.Component):with(self.Networked):iter() do
			local previous = self.world:get(id, pair(self._Previous, component))
			if previous ~= value then
				full_changes[id] = full_changes[id] or {}
				full_changes[id][name] = if value == nil then NOTHING else value
				self.world:set(id, pair(self._Previous, component), value)
			end
		end
	end

	for id in self._queries.previous:iter() do
		for _, component in get_targets(self.world, id, self._Previous) do
			local name = self.world:get(component, jecs.Name) :: string
			if not self.world:has(id, component) then
				full_changes[id] = full_changes[id] or {}
				full_changes[id][name] = DELETED
				self.world:remove(id, pair(self._Previous, component))
			end
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

		for _, component in get_targets(self.world, id, self.Networked) do
			local name = self.world:get(component, jecs.Name) :: string
			local scoped_players = self.world:get(id, pair(self.Networked, component))
			local previous_scoped_players = self.world:get(id, pair(self._Previous, pair(self.Networked, component)))

			for _, player in all_players do
				local is_allowed = scoped_players == nil or table.find(scoped_players, player) ~= nil
				local was_allowed = previous_scoped_players == nil or table.find(previous_scoped_players, player) ~= nil

				filtered_changes[player][id] = filtered_changes[player][id] or {}
				local local_changes = filtered_changes[player][id]
				local should_write = local_changes ~= DELETED and (local_changes[name] or was_allowed)

				if not is_allowed and should_write then
					local_changes[name] = DELETED
				end
			end

			self.world:set(id, pair(self._Previous, pair(self.Networked, component)), scoped_players)
		end
	end

	for _, player in self._awaiting_hydration do
		filtered_changes[player] = hydrate(self, player)
	end
	table.clear(self._awaiting_hydration)

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
			previous = world:query(pair(Previous, jecs.Wildcard)):with(Networked):cached(),
		},
		_awaiting_hydration = {},
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

	Players.PlayerAdded:Connect(function(player)
		table.insert(mirror._awaiting_hydration, player)
	end)

	return mirror
end

return { new = new }
