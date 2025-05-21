local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

assert(RunService:IsServer(), "ReplicaService can only be required by the server")

local ReplicaClass
local Remote = require(script.Parent.ReplicaShared.Remote)

export type ReplicaToken = {
	_replicaId: string,
	GetReplicaId: (self: ReplicaToken) -> string
}

export type Config = {
	Tags: {any},
	Data: any | {any}
}

export type Replica = {
	_id: string,
	_tags: {string},
	Data: {[string]: any},
	_children: {Replica},
	_parent: Replica?,
	_parentId: string?,
	_token: any?,
	_signals: {[string]: {(any) -> ()}}?,
	_listeners: {[string]: {(...any) -> ()}}?,

	GetId: (self: Replica) -> string,
	GetTags: (self: Replica) -> {string},
	GetParent: (self: Replica) -> Replica?,
	GetParentId: (self: Replica) -> string?,
	GetChildren: (self: Replica) -> {Replica},

	-- Server-side methods
	SetValue: (self: Replica, path: string, value: any) -> any,
	ArrayInsert: (self: Replica, arrayPath: string, index: number?, value: any) -> number,
	ArrayRemove: (self: Replica, arrayPath: string, index: number) -> any,
	SetParent: (self: Replica, parentReplica: Replica?) -> (),
	Destroy: (self: Replica) -> (),
}

-- Main ReplicaService module
local ReplicaService = {
	_replicasByTag = {}, -- Map of replicas organized by tag
	_replicasById = {}, -- Map of replicas by their unique ID
	_nextReplicaId = 0, -- Counter for generating unique IDs
	_playerSubscriptions = {}, -- Map of player subscriptions by player and replica
	_isInitialized = false, -- Initialization state
	_remote = nil -- Remote instance
}

-- ReplicaToken class for authenticating server-side write operations
local ReplicaToken = {}
ReplicaToken.__index = ReplicaToken

--[[
  Create a new replica token
  @param replicaId string - ID of the replica this token authenticates
  @return ReplicaToken - New token instance
]]
function ReplicaToken.new(replicaId: string): ReplicaToken
	local self = setmetatable({}, ReplicaToken)
	self._replicaId = replicaId
	return self
end

--[[
  Get the replica ID associated with this token
  @return string - The replica ID
]]
function ReplicaToken:GetReplicaId(): string
	return self._replicaId
end

--[[
  Create a unique replica ID
  @return string - Unique ID for a new replica
]]
local function createReplicaId(): string
	ReplicaService._nextReplicaId += 1
	return tostring(ReplicaService._nextReplicaId)
end

--[[
  Initialize the ReplicaService
  @return self
]]
function ReplicaService:Initialize()
	if self._isInitialized then
		warn("ReplicaService has already been initialized")
		return self
	end

	ReplicaClass = require(script.Parent.ReplicaShared.Replica)

	-- Set up remote event for client communication
	self._remote = Remote.new("ReplicaEvent")
	
	self._remote:RegisterHandler("RequestData", function(player)
		self:_handleDataRequest(player)
	end)

	-- Clean up player subscriptions when player leaves
	Players.PlayerRemoving:Connect(function(player)
		self._playerSubscriptions[player] = nil
	end)

	self._isInitialized = true
	return self
end

--[[
	Waits for the Service to initialize
]]
function ReplicaService:WaitForInitialization()
	while not self._isInitialized do
		task.wait()
	end
end

--[[
  Create a new replica
  @param Config table - Configuration with Tags and Data
  @return Replica - The newly created replica
]]
function ReplicaService:CreateReplica(Config: Config): Replica
	assert(self._isInitialized, "ReplicaService must be initialized before creating replicas")
	assert(typeof(Config) == "table", "Replica Config must be a table")

	-- Generate unique ID and create token
	local replicaId = createReplicaId()
	local replicaToken = ReplicaToken.new(replicaId)

	-- Create replica instance
	local replica = ReplicaClass.new(replicaId, Config.Tags, Config.Data, replicaToken)

	-- Store by ID
	self._replicasById[replicaId] = replica

	-- Store by tags
	for _, tag in ipairs(Config.Tags) do
		if not self._replicasByTag[tag] then
			self._replicasByTag[tag] = {}
		end
		table.insert(self._replicasByTag[tag], replica)
	end

	return replica
end

--[[
  Get all replicas with the specified tags
  @param tags {string} - Array of tags to filter by
  @return {Replica} - Array of matching replicas
]]
function ReplicaService:GetReplicasWithTags(tags: {string}): {Replica}
	if #tags == 0 then
		return {}
	end

	-- Start with all replicas that have the first tag
	local firstTag = tags[1]
	local filteredReplicas = self._replicasByTag[firstTag] or {}

	-- If only one tag was provided, return those replicas
	if #tags == 1 then
		return filteredReplicas
	end

	-- Otherwise, filter for replicas that have ALL the requested tags
	local result = {}
	for _, replica in filteredReplicas do
		local hasAllTags = true

		-- Check if replica has all the remaining tags
		for i = 2, #tags do
			local tag = tags[i]
			if not replica:HasTag(tag) then
				hasAllTags = false
				break
			end
		end

		if hasAllTags then
			table.insert(result, replica)
		end
	end

	return result
end

--[[
  Get a replica by its ID
  @param replicaId string - ID of the replica to find
  @return Replica? - The replica if found, nil otherwise
]]
function ReplicaService:GetReplicaById(replicaId: string): Replica?
	return self._replicasById[replicaId]
end

--[[
  Subscribe a player to receive updates for a specific replica
  @param player Player - Player to subscribe
  @param replica Replica - Replica to subscribe to
]]
function ReplicaService:SubscribePlayer(player: Player, replica: Replica)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Invalid player")

	local replicaId = replica:GetId()

	-- Initialize player's subscription table if needed
	if not self._playerSubscriptions[player] then
		self._playerSubscriptions[player] = {}
	end

	-- Skip if already subscribed
	if self._playerSubscriptions[player][replicaId] then
		return
	end

	-- Mark as subscribed
	self._playerSubscriptions[player][replicaId] = true

	-- Send replica creation to client
	self._remote:FireClient(player, "Create", replicaId, 
		replica:GetTags(), replica.Data, replica:GetParentId())
end

--[[
  Unsubscribe a player from a replica's updates
  @param player Player - Player to unsubscribe
  @param replica Replica - Replica to unsubscribe from
]]
function ReplicaService:UnsubscribePlayer(player: Player, replica: Replica)
	if not self._playerSubscriptions[player] then return end

	local replicaId = replica:GetId()
	self._playerSubscriptions[player][replicaId] = nil

	-- Send replica destruction to client
	self._remote:FireClient(player, "Destroy", replicaId)
end

--[[
  Subscribe a player to all replicas with the specified tags
  @param player Player - Player to subscribe
  @param tags {string} - Tags to filter replicas by
]]
function ReplicaService:SubscribePlayerToTags(player: Player, tags: {string})
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Invalid player")
	assert(type(tags) == "table", "Tags must be a table")

	-- Handle single tag case
	if #tags == 1 then
		local tag = tags[1]
		local replicas = self._replicasByTag[tag] or {}
		for _, replica in replicas do
			self:SubscribePlayer(player, replica)
		end
		return
	end

	-- Multiple tags case - find replicas with all specified tags
	local replicas = self:GetReplicasWithTags(tags)
	for _, replica in replicas do
		self:SubscribePlayer(player, replica)
	end
end

--[[
  Get all players subscribed to a specific replica
  @param replicaId string - ID of the replica
  @return {Player} - Array of subscribed players
]]
function ReplicaService:GetSubscribedPlayers(replicaId: string): {Player}
	local subscribedPlayers = {}

	for player, subscriptions in self._playerSubscriptions do
		if subscriptions[replicaId] then
			table.insert(subscribedPlayers, player)
		end
	end

	return subscribedPlayers
end

--[[
  Destroy a replica and notify all subscribed players
  @param replica Replica - Replica to destroy
]]
function ReplicaService:DestroyReplica(replica)
	assert(typeof(replica) == "table" and replica.GetId, "Invalid replica")

	local replicaId = replica:GetId()

	-- Notify subscribed players
	local subscribedPlayers = self:GetSubscribedPlayers(replicaId)
	if #subscribedPlayers > 0 then
		self._remote:FireClients(subscribedPlayers, "Destroy", replicaId)
	end

	-- Remove from tag maps
	for tag, replicas in self._replicasByTag do
		for i, r in replicas do
			if r:GetId() == replicaId then
				table.remove(replicas, i)
				break
			end
		end
	end

	-- Remove from ID map
	self._replicasById[replicaId] = nil

	-- Clear subscriptions
	for player, subscriptions in pairs(self._playerSubscriptions) do
		subscriptions[replicaId] = nil
	end
end

--[[
  Get replicas with a single tag
  @param tag string - Tag to filter by
  @return {Replica} - Array of matching replicas
]]
function ReplicaService:GetReplicasWithTag(tag: string): {Replica}
	return self._replicasByTag[tag] or {}
end

--[[
  Handle data request from client
  @param player Player - Player requesting data
]]
function ReplicaService:_handleDataRequest(player)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Invalid player")

	-- Resend all replicas the player is subscribed to
	if self._playerSubscriptions[player] then
		for replicaId, _ in self._playerSubscriptions[player] do
			local replica = self:GetReplicaById(replicaId)
			if replica then
				print(replica)
				self._remote:FireClient(player, "Create", replicaId, replica:GetTags(), replica.Data, replica:GetParentId())
			end
		end
	end
end

--[[
  Handle update events from replicas and broadcast to subscribed players
  @param token ReplicaToken - Authentication token
  @param actionType string - Type of action (update, arrayInsert, arrayRemove, setParent)
  @param path string - Data path
  @param ... any - Additional arguments based on action type
]]
function ReplicaService:_replicaUpdateHandler(token, actionType, path, ...)
	assert(typeof(token) == "table" and token.GetReplicaId, "Invalid replica token")

	local replicaId = token:GetReplicaId()
	local subscribedPlayers = self:GetSubscribedPlayers(replicaId)

	if #subscribedPlayers == 0 then return end

	if actionType == "update" then
		local value = ...
		self._remote:FireClients(subscribedPlayers, "Update", replicaId, path, value)
	elseif actionType == "arrayInsert" then
		local index, value = ...
		self._remote:FireClients(subscribedPlayers, "ArrayInsert", replicaId, path, index, value)
	elseif actionType == "arrayRemove" then
		local index = ...
		self._remote:FireClients(subscribedPlayers, "ArrayRemove", replicaId, path, index)
	elseif actionType == "setParent" then
		local parentId = ...
		self._remote:FireClients(subscribedPlayers, "SetParent", replicaId, parentId)
	end
end

return ReplicaService
