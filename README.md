# Replica Framework with Remote System
A flexible data replication system for Roblox games with an enhanced Remote communication layer.

## Overview
This framework provides a robust client-server data synchronization system for Roblox games. It consists of three main components:

1. **ReplicaService** - Server-side management of replicated data
2. **ReplicaController** - Client-side consumption of replicated data

The system allows developers to create, update, and destroy replicated data structures that automatically synchronize between server and clients with minimal network overhead.

## Features
- **Data Replication**: Automatically sync data between server and clients
- **Tag-based Filtering**: Subscribe clients only to relevant data
- **Hierarchical Structure**: Support for parent-child relationships between replicas
- **Efficient Updates**: Only send changed data over the network
- **Custom Remote Events**: Organize network traffic with named remote events
- **Flexible Subscription**: Fine-grained control over which players receive updates

## Usage
### Server-Side (ReplicaService)
```luau
local ReplicaService = require(path.to.ReplicaService)

-- Initialize the service
ReplicaService:Initialize()

-- Create a new replica
local playerDataReplica = ReplicaService:CreateReplica(
    { -- Initial data
        gold = 100,
        level = 1,
        inventory = {
            items = {}
        }
    }
    {"PlayerData", "Save"},   -- Tags for filtering
)

-- Subscribe a player to the replica
ReplicaService:SubscribePlayer(player, playerDataReplica)

-- Update replica data
playerDataReplica:SetValue({"gold"}, 150)
playerDataReplica:SetValue({"level"}, 2)

-- Add an item to an array
playerDataReplica:ArrayInsert({"inventory", "items"}, {id = "sword", damage = 10})

-- Destroy the replica when no longer needed
ReplicaService:DestroyReplica(playerDataReplica)
```

### Client-Side (ReplicaController)
```luau
local ReplicaController = require(path.to.ReplicaController)

-- Initialize the controller
ReplicaController:Initialize()

-- Get replicas with a specific tag
local playerData = ReplicaController:GetReplicasWithTag("PlayerData")[1]

-- Or wait for a replica to be created
local playerData = ReplicaController:WaitForReplicaWithTag("PlayerData")

-- Listen for data changes
playerData:ListenToChange({"gold"}, function(newGold)
    print("Gold updated to:", newGold)
    -- Update UI or perform other actions
end)

-- Get current data
local currentGold = playerData:GetValue({"gold"})
local inventory = playerData:GetValue({"inventory", "items"})
```

## Advanced Usage
### Parent-Child Relationships
Create hierarchical data structures:

```lua
-- Server
local gameReplica = ReplicaService:CreateReplica("Game", {"Game"}, gameData)
local roundReplica = ReplicaService:CreateReplica("Round", {"Round"}, roundData)

-- Set parent
roundReplica:SetParent(gameReplica:GetId())

-- Client
local gameReplica = ReplicaController:WaitForReplicaWithTag("Game")
local childReplicas = gameReplica:GetChildren()
```

### Filtering with Predicates
Find specific replicas with custom predicates:

```lua
local highLevelPlayers = ReplicaController:FindFirstReplicaWithPredicate(function(replica)
    return replica:GetValue({"level"}) > 10
end)
```

## API Reference
### ReplicaService
```lua
local ReplicaService = require(path.to.ReplicaService)

-- Core methods
ReplicaService:Initialize()
ReplicaService:CreateReplica(tags, dataTable)
ReplicaService:DestroyReplica(replica)

-- Subscription methods
ReplicaService:SubscribePlayer(player, replica)
ReplicaService:UnsubscribePlayer(player, replica)
ReplicaService:SubscribePlayerToTags(player, tags)
ReplicaService:GetSubscribedPlayers(replicaId)

-- Query methods
ReplicaService:GetReplicasWithTag(tag)
ReplicaService:GetReplicaById(replicaId)
```

### ReplicaController
```lua
local ReplicaController = require(path.to.ReplicaController)

-- Core methods
ReplicaController:Initialize()

-- Query methods
ReplicaController:GetReplicaById(replicaId)
ReplicaController:GetReplicasWithTag(tag)

-- Utility methods
ReplicaController:WaitForReplicaWithTag(tag, timeout)
ReplicaController:FindFirstReplicaWithPredicate(predicate, timeout)
```

### Replica Class
```lua
-- Get data
replica:GetId()
replica:GetTags()
replica:GetData()
replica:GetValue(path)
replica:GetParent()
replica:GetChildren()

-- Modify data (server only)
replica:SetValue(path, value)
replica:ArrayInsert(path, value, index)
replica:ArrayRemove(path, index)
replica:SetParent(parentId)

-- Listen to changes (client)
replica:ListenToChange(path, callback)
replica:ListenToArrayInsert(path, callback)
replica:ListenToArrayRemove(path, callback)
replica:ListenToParentChange(callback)
```

## Contributing
Contributions are welcome! If you find bugs or have suggestions for improvements, please open an issue or submit a pull request.
