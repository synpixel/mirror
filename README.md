# Mirror

Mirror is a simple replication library for [jecs](https://github.com/Ukendio/jecs) inspired by [feces](https://github.com/NeonD00m/feces).

## Quick Start

### Server

```lua
local mirror = Mirror.new(world)

local Temperature = world:component() :: jecs.Entity<number>
world:set(Temperature, jecs.Name, "Temperature") -- Mirror relies on `jecs.Name` for component replication
world:add(Temperature, mirror.Networked)

local function on_player_added(player: Player)
    local x = world:entity()
    world:set(x, Temperature, 0)
    world:add(x, mirror.Networked, { player }) -- Only allow this specific player to see this entity and its components

    -- Provide new players with the entire buffer
    local changes = mirror:hydrate(player)
    replicate:FireClient(player, changes)
end

local function on_every_frame(delta_time: number)
    for id, temperature in world:query(Temperature):iter() do
        world:set(id, Temperature, temperature + delta_time)
    end

    for player, changes in mirror:collect() do
        replicate:FireClient(player, changes)
    end
end
```

### Client

```lua
local mirror = Mirror.new(world)

-- The component should exist in both contexts
local Temperature = world:component() :: jecs.Entity<number>
world:set(Temperature, jecs.Name, "Temperature")
world:add(Temperature, mirror.Networked)

local function on_every_frame()
    for id, temperature in world:query(Temperature):iter() do
		print(`entity #{id} is {temperature}°`)
	end
end

replicate.OnClientEvent:Connect(function(changes)
    mirror:apply(changes)
end)
```
