local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

assert(RunService:IsServer(), "ReplicaService can only be required by the server")

local ReplicaClass
local Remote = require(script.Parent.Remote)

local ReplicaService = {
	_replicasByTag = {}, -- map of replicas organized by tag
	_replicasById = {}, -- map of replicas by their unique id
	_nextReplicaId = 0, -- counter for generating unique ids
	_playerSubscriptions = {}, -- map of player subscriptions by player and replica
	_isInitialized = false, -- initialization state
	_remote = nil -- remote instance
}

-- authentication token for server-side write operations
local ReplicaToken = {}
ReplicaToken.__index = ReplicaToken

function ReplicaToken.new(replicaId)
	-- creates a new token with replica id
	local self = setmetatable({}, ReplicaToken)
	self._replicaId = replicaId
	return self
end

function ReplicaToken:GetReplicaId()
	-- returns the replica id associated with this token
	return self._replicaId
end

local function createReplicaId()
	-- creates a unique replica id
	ReplicaService._nextReplicaId += 1
	return tostring(ReplicaService._nextReplicaId)
end

function ReplicaService:Initialize()
	-- initializes the service
	if self._isInitialized then
		warn("ReplicaService has already been initialized")
		return self
	end

	ReplicaClass = require(script.Parent.Replica)

	-- initialize the Remote class with custom names
	self._remote = Remote.new("ReplicaEvent", "ReplicaRemotes")

	-- register remote handlers
	-- note: we don't need handlers for client->server communication in this case
	-- as all operations are initiated by the server in this architecture

	Players.PlayerRemoving:Connect(function(player)
		self._playerSubscriptions[player] = nil
	end)

	self._isInitialized = true
	return self
end

function ReplicaService:CreateReplica(template, tags, dataTable)
	-- creates a new replica with specified template, tags and data
	assert(self._isInitialized, "ReplicaService must be initialized before creating replicas")
	assert(typeof(template) == "string", "Replica template must be a string")
	assert(typeof(tags) == "table", "Replica tags must be a table")
	assert(typeof(dataTable) == "table", "Replica data must be a table")

	local replicaId = createReplicaId()
	local replicaToken = ReplicaToken.new(replicaId)
	local replica = ReplicaClass.new(replicaId, template, tags, dataTable, replicaToken)

	self._replicasById[replicaId] = replica

	for _, tag in ipairs(tags) do
		if not self._replicasByTag[tag] then
			self._replicasByTag[tag] = {}
		end
		table.insert(self._replicasByTag[tag], replica)
	end

	return replica
end

function ReplicaService:GetReplicasWithTag(tag)
	-- returns all replicas with the specified tag
	return self._replicasByTag[tag] or {}
end

function ReplicaService:GetReplicaById(replicaId)
	-- returns replica with the specified id or nil if not found
	return self._replicasById[replicaId]
end

function ReplicaService:SubscribePlayer(player, replica)
	-- subscribes player to replica updates
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Invalid player")

	local replicaId = replica:GetId()

	if not self._playerSubscriptions[player] then
		self._playerSubscriptions[player] = {}
	end

	if self._playerSubscriptions[player][replicaId] then
		return
	end

	self._playerSubscriptions[player][replicaId] = true

	-- Send replica creation to client using the Remote class
	self._remote:FireClient(player, "Create", replicaId, replica:GetTemplate(), 
		replica:GetTags(), replica:GetData(), replica:GetParentId())
end

function ReplicaService:UnsubscribePlayer(player, replica)
	-- unsubscribes player from replica updates
	if not self._playerSubscriptions[player] then return end

	local replicaId = replica:GetId()
	self._playerSubscriptions[player][replicaId] = nil

	-- Send replica destruction to client
	self._remote:FireClient(player, "Destroy", replicaId)
end

function ReplicaService:SubscribePlayerToTags(player, tags)
	-- subscribes player to all replicas with specified tags
	for _, tag in ipairs(tags) do
		local replicas = self:GetReplicasWithTag(tag)
		for _, replica in ipairs(replicas) do
			self:SubscribePlayer(player, replica)
		end
	end
end

function ReplicaService:GetSubscribedPlayers(replicaId)
	-- returns all players subscribed to the specified replica
	local subscribedPlayers = {}

	for player, subscriptions in pairs(self._playerSubscriptions) do
		if subscriptions[replicaId] then
			table.insert(subscribedPlayers, player)
		end
	end

	return subscribedPlayers
end

function ReplicaService:DestroyReplica(replica)
	-- destroys replica and notifies all subscribed players
	local replicaId = replica:GetId()

	local subscribedPlayers = self:GetSubscribedPlayers(replicaId)
	if #subscribedPlayers > 0 then
		self._remote:FireClients(subscribedPlayers, "Destroy", replicaId)
	end

	for tag, replicas in pairs(self._replicasByTag) do
		for i, r in ipairs(replicas) do
			if r:GetId() == replicaId then
				table.remove(replicas, i)
				break
			end
		end
	end

	self._replicasById[replicaId] = nil

	for player, subscriptions in pairs(self._playerSubscriptions) do
		subscriptions[replicaId] = nil
	end
end

function ReplicaService:_replicaUpdateHandler(token, actionType, path, ...)
	-- handles update events from replicas and broadcasts to subscribed players
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
