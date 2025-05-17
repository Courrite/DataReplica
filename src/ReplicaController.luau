local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

assert(RunService:IsClient(), "ReplicaController can only be required by the client")

local ReplicaClass = require(script.Parent.ReplicaShared.Replica)
local Remote = require(script.Parent.ReplicaShared.Remote)
local Signal = require(script.Parent.ReplicaShared.Signal)

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

	-- Client-side methods
	ConnectOnChange: (self: Replica, path: string, callback: (any) -> ()) -> {Disconnect: () -> ()},
	AddGlobalListener: (self: Replica, listenerType: string, callback: (...any) -> ()) -> {Disconnect: () -> ()},
	_handleDataUpdate: (self: Replica, path: string, value: any) -> (),
	_handleArrayInsert: (self: Replica, path: string, index: number, value: any) -> (),
	_handleArrayRemove: (self: Replica, path: string, index: number) -> (),
	_handleSetParent: (self: Replica, parentId: string?) -> (),
}

local ReplicaController = {
	_replicasById = {}, -- Map of replicas by their unique ID
	_replicasByTag = {}, -- Map of replicas organized by tag
	_pendingChildren = {}, -- Children waiting for parents to be created
	_isInitialized = false,
	_remote = nil, -- remote instance
	ReplicaCreated = Signal.new(), -- fired when a replica is created
	ReplicaDestroyed = Signal.new() -- fired when a replica is destroyed (token, replicaId)
} :: typeof(setmetatable(ReplicaController, setmetatable({__index = ReplicaController})))

function ReplicaController:Initialize()
	if self._isInitialized then
		warn("ReplicaController has already been initialized")
		return self
	end

	-- initialize the Remote class with custom names
	self._remote = Remote.new("ReplicaEvent", "ReplicaRemotes")

	-- register handlers for each action
	self._remote:RegisterHandler("Create", function(...)
		self:_handleReplicaCreate(...)
	end)

	self._remote:RegisterHandler("Update", function(...)
		self:_handleReplicaUpdate(...)
	end)

	self._remote:RegisterHandler("ArrayInsert", function(...)
		self:_handleReplicaArrayInsert(...)
	end)

	self._remote:RegisterHandler("ArrayRemove", function(...)
		self:_handleReplicaArrayRemove(...)
	end)

	self._remote:RegisterHandler("SetParent", function(...)
		self:_handleReplicaSetParent(...)
	end)

	self._remote:RegisterHandler("Destroy", function(...)
		self:_handleReplicaDestroy(...)
	end)

	self._isInitialized = true
	return self
end

function ReplicaController:_handleReplicaCreate(replicaId, tags, data, parentId)
	local replica = ReplicaClass.new(replicaId, tags, data)

	self._replicasById[replicaId] = replica

	for _, tag in ipairs(tags) do
		if not self._replicasByTag[tag] then
			self._replicasByTag[tag] = {}
		end
		table.insert(self._replicasByTag[tag], replica)
	end

	if parentId then
		local parent = self._replicasById[parentId]
		if parent then
			replica._parentId = parentId
			replica._parent = parent
			table.insert(parent._children, replica)
		else
			if not self._pendingChildren[parentId] then
				self._pendingChildren[parentId] = {}
			end
			table.insert(self._pendingChildren[parentId], replica)
		end
	end

	if self._pendingChildren[replicaId] then
		for _, child in ipairs(self._pendingChildren[replicaId]) do
			child._parentId = replicaId
			child._parent = replica
			table.insert(replica._children, child)
		end
		self._pendingChildren[replicaId] = nil
	end

	-- fire creation signal
	self.ReplicaCreated:Fire(replica)
end

function ReplicaController:_handleReplicaUpdate(replicaId, path, value)
	local replica = self._replicasById[replicaId]
	if replica then
		replica:_handleDataUpdate(path, value)
	end
end

function ReplicaController:_handleReplicaArrayInsert(replicaId, path, index, value)
	local replica = self._replicasById[replicaId]
	if replica then
		replica:_handleArrayInsert(path, index, value)
	end
end

function ReplicaController:_handleReplicaArrayRemove(replicaId, path, index)
	local replica = self._replicasById[replicaId]
	if replica then
		replica:_handleArrayRemove(path, index)
	end
end

function ReplicaController:_handleReplicaSetParent(replicaId, parentId)
	local replica = self._replicasById[replicaId]
	if replica then
		-- remove from previous parent
		if replica._parent then
			local children = replica._parent._children
			for i, child in ipairs(children) do
				if child == replica then
					table.remove(children, i)
					break
				end
			end
		end

		-- assign new parent
		if parentId then
			local parent = self._replicasById[parentId]
			if parent then
				replica._parent = parent
				table.insert(parent._children, replica)
			else
				replica._parent = nil
				if not self._pendingChildren[parentId] then
					self._pendingChildren[parentId] = {}
				end
				table.insert(self._pendingChildren[parentId], replica)
			end
		else
			replica._parent = nil
		end

		replica:_handleSetParent(parentId)
	end
end

function ReplicaController:_handleReplicaDestroy(replicaId)
	local replica = self._replicasById[replicaId]
	if not replica then return end

	-- remove reference
	self._replicasById[replicaId] = nil

	-- remove from tag lists
	for tag, replicas in self._replicasByTag do
		for i, r in ipairs(replicas) do
			if r:GetId() == replicaId then
				table.remove(replicas, i)
				break
			end
		end
	end

	-- clear parent reference
	if replica._parent then
		local children = replica._parent._children
		for i, child in ipairs(children) do
			if child == replica then
				table.remove(children, i)
				break
			end
		end
	end

	-- clear pending children
	self._pendingChildren[replicaId] = nil

	-- fire deletion signal
	self.ReplicaDestroyed:Fire(replica._token, replicaId)
end

-- public methods
function ReplicaController:GetReplicaById(replicaId)
	return self._replicasById[replicaId]
end

function ReplicaController:GetReplicasWithTags(tags: {string}): {Replica}
	if #tags == 0 then
		return {}
	end

	local firstTag = tags[1]
	local filteredReplicas = self._replicasByTag[firstTag] or {}
	local result = {}

	if #tags == 1 then
		return filteredReplicas
	end

	for _, replica in filteredReplicas do
		local hasAllTags = true
		for i = 2, #tags do
			if not replica:HasTag(tags[i]) then
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

function ReplicaController:WaitForReplicaWithTags(tags, timeout)
	assert(type(tags) == "table" and #tags > 0, "Tags must be a non-empty array")
	timeout = timeout or 10
	local startTime = os.clock()

	while os.clock() - startTime < timeout do
		local replicas = self:GetReplicasWithTags(tags)
		if #replicas > 0 then
			return replicas[1]
		end
		task.wait(0.1)
	end

	return nil
end

function ReplicaController:FindFirstReplicaWithPredicate(predicate, timeout)
	assert(typeof(predicate) == "function", "Predicate must be a function")
	timeout = timeout or 10
	local startTime = os.clock()

	while os.clock() - startTime < timeout do
		for _, replica in self._replicasById do
			if predicate(replica) then
				return replica
			end
		end
		task.wait(0.1)
	end

	return nil
end

return ReplicaController
