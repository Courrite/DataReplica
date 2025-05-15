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
	_data: {[string]: any},
	_children: {Replica},
	_parent: Replica?,
	_parentId: string?,
	_token: any?,
	_signals: {[string]: {(any) -> ()}}?,
	_listeners: {[string]: {(...any) -> ()}}?,

	GetId: (self: Replica) -> string,
	GetTags: (self: Replica) -> {string},
	GetData: (self: Replica) -> {[string]: any},
	GetParent: (self: Replica) -> Replica?,
	GetParentId: (self: Replica) -> string?,
	GetChildren: (self: Replica) -> {Replica},

	-- Server-side methods
	SetValue: (self: Replica, path: string, value: any) -> any,
	ArrayInsert: (self: Replica, arrayPath: string, index: number?, value: any) -> number,
	ArrayRemove: (self: Replica, arrayPath: string, index: number) -> any,
	SetParent: (self: Replica, parentReplica: Replica?) -> (),
	Destroy: (self: Replica) -> (),

	-- Client-side methods
	--ConnectOnChange: ((self: Replica, path: string, callback: (any) -> ()) -> {Disconnect: () -> ()})?,
	--AddGlobalListener: ((self: Replica, listenerType: string, callback: (...any) -> ()) -> {Disconnect: () -> ()})?,
	--_handleDataUpdate: ((self: Replica, path: string, value: any) -> ())?,
	--_handleArrayInsert: ((self: Replica, path: string, index: number, value: any) -> ())?,
	--_handleArrayRemove: ((self: Replica, path: string, index: number) -> ())?,
	--_handleSetParent: ((self: Replica, parentId: string?) -> ())?,
}

export type ReplicaService = {
	_replicasByTag: {[string]: Replica},
	_replicasById: {[string]: Replica},
	_nextReplicaId: number,
	_playerSubscriptions: {[any]: {[string]: boolean}},
	_isInitialized: boolean,
	_remote: any,

	Initialize: (self: ReplicaService) -> ReplicaService,
	CreateReplica: (self: ReplicaService, Config: Config) -> Replica,
	GetReplicasWithTags: (self: ReplicaService, tag: {string}) -> {Replica},
	GetReplicaById: (self: ReplicaService, replicaId: string) -> Replica?,
	SubscribePlayer: (self: ReplicaService, player: Player, replica: Replica) -> (),
	UnsubscribePlayer: (self: ReplicaService, player: Player, replica: Replica) -> (),
	SubscribePlayerToTags: (self: ReplicaService, player: Player, tags: {string}) -> (),
	GetSubscribedPlayers: (self: ReplicaService, replicaId: string) -> {Player},
	DestroyReplica: (self: ReplicaService, replica: any) -> (),

	_replicaUpdateHandler: (self: ReplicaService, token: ReplicaToken, actionType: string, path: string, ...any) -> ()
}

local ReplicaService = {
	_replicasByTag = {}, -- map of replicas organized by tag
	_replicasById = {}, -- map of replicas by their unique id
	_nextReplicaId = 0, -- counter for generating unique ids
	_playerSubscriptions = {}, -- map of player subscriptions by player and replica
	_isInitialized = false, -- initialization state
	_remote = nil -- remote instance
} :: ReplicaService

-- authentication token for server-side write operations
local ReplicaToken = {}
ReplicaToken.__index = ReplicaToken

function ReplicaToken.new(replicaId: string): ReplicaToken
	-- creates a new token with replica id
	local self = setmetatable({}, ReplicaToken)
	self._replicaId = replicaId
	return self
end

function ReplicaToken:GetReplicaId(): string
	-- returns the replica id associated with this token
	return self._replicaId
end

local function createReplicaId(): string
	-- creates a unique replica id
	ReplicaService._nextReplicaId += 1
	return tostring(ReplicaService._nextReplicaId)
end

function ReplicaService:Initialize(): ReplicaService
	-- initializes the service
	if self._isInitialized then
		warn("ReplicaService has already been initialized")
		return self
	end

	ReplicaClass = require(script.Parent.ReplicaShared.Replica)

	-- initialize the Remote class with custom names
	self._remote = Remote.new("ReplicaEvent")

	Players.PlayerRemoving:Connect(function(player)
		self._playerSubscriptions[player] = nil
	end)

	self._isInitialized = true
	return self
end

function ReplicaService:CreateReplica(Config: Config): Replica
	-- creates a new replica with specified tags and data
	assert(self._isInitialized, "ReplicaService must be initialized before creating replicas")
	assert(typeof(Config) == "table", "Replica Config must be a table")

	local replicaId = createReplicaId()
	local replicaToken = ReplicaToken.new(replicaId)
	local replica = ReplicaClass.new(replicaId, Config.Tags, Config.Data, replicaToken)

	self._replicasById[replicaId] = replica

	for _, tag in ipairs(Config.Tags) do
		if not self._replicasByTag[tag] then
			self._replicasByTag[tag] = {}
		end
		table.insert(self._replicasByTag[tag], replica)
	end

	return replica
end

function ReplicaService:GetReplicasWithTags(tags: {string}): {Replica}
	if #tags == 0 then
		return {}
	end

	-- start with all replicas that have the first tag
	local firstTag = tags[1]
	local filteredReplicas = self._replicasByTag[firstTag] or {}
	local result = {}

	-- if only one tag was provided, return those replicas
	if #tags == 1 then
		return filteredReplicas
	end

	-- otherwise, filter for replicas that have ALL the requested tags
	for _, replica in pairs(filteredReplicas) do
		local hasAllTags = true

		-- check if replica has all the remaining tags
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

function ReplicaService:GetReplicaById(replicaId: string): Replica?
	-- returns replica with the specified id or nil if not found
	return self._replicasById[replicaId]
end

function ReplicaService:SubscribePlayer(player: Player, replica: Replica)
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
	self._remote:FireClient(player, "Create", replicaId, 
		replica:GetTags(), replica:GetData(), replica:GetParentId())
end

function ReplicaService:UnsubscribePlayer(player: Player, replica: Replica)
	-- unsubscribes player from replica updates
	if not self._playerSubscriptions[player] then return end

	local replicaId = replica:GetId()
	self._playerSubscriptions[player][replicaId] = nil

	-- Send replica destruction to client
	self._remote:FireClient(player, "Destroy", replicaId)
end

function ReplicaService:SubscribePlayerToTags(player: Player, tags: {string})
	-- subscribes player to all replicas with specified tags
	for _, tag in ipairs(tags) do
		local replicas = self:GetReplicasWithTag(tag)
		for _, replica in ipairs(replicas) do
			self:SubscribePlayer(player, replica)
		end
	end
end

function ReplicaService:GetSubscribedPlayers(replicaId: string): {Player}
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
