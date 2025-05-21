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

	Changed: RBXScriptSignal,
	Destroyed: RBXScriptSignal,
	_handleDataUpdate: (self: Replica, path: string, value: any) -> (),
	_handleArrayInsert: (self: Replica, path: string, index: number, value: any) -> (),
	_handleArrayRemove: (self: Replica, path: string, index: number) -> (),
	_handleSetParent: (self: Replica, parentId: string?) -> (),
}

-- Main ReplicaController module
local ReplicaController = {
	_replicasById = {}, -- Map of replicas by their unique ID
	_replicasByTag = {}, -- Map of replicas organized by tag
	_pendingChildren = {}, -- Children waiting for parents to be created
	_isInitialized = false,
	_remote = nil, -- Remote instance
	ReplicaCreated = Signal.new(), -- Signal fired when a replica is created
	ReplicaDestroyed = Signal.new() -- Signal fired when a replica is destroyed
}

--[[
  Initialize the ReplicaController and set up all necessary handlers
  @return self
]]
function ReplicaController:Initialize()
	if self._isInitialized then
		warn("ReplicaController has already been initialized")
		return self
	end

	-- Initialize the Remote class with custom names
	self._remote = Remote.new("ReplicaEvent")

	-- Register handlers for each action type
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

--[[
  Handle replica creation from server
  @param replicaId string - Unique ID of the replica
  @param tags {string} - Array of tags for the replica
  @param data table - Data table for the replica
  @param parentId string? - Optional parent replica ID
]]
function ReplicaController:_handleReplicaCreate(replicaId, tags, data, parentId)
	-- Create new replica instance
	local replica = ReplicaClass.new(replicaId, tags, data)

	-- Store by ID
	self._replicasById[replicaId] = replica

	-- Store by tags
	for _, tag in ipairs(tags) do
		if not self._replicasByTag[tag] then
			self._replicasByTag[tag] = {}
		end
		table.insert(self._replicasByTag[tag], replica)
	end

	-- Handle parent-child relationships
	if parentId then
		local parent = self._replicasById[parentId]
		if parent then
			-- Parent exists, attach directly
			replica._parentId = parentId
			replica._parent = parent
			table.insert(parent._children, replica)
		else
			-- Parent doesn't exist yet, queue for later attachment
			if not self._pendingChildren[parentId] then
				self._pendingChildren[parentId] = {}
			end
			table.insert(self._pendingChildren[parentId], replica)
		end
	end

	-- If there are pending children for this replica, attach them
	if self._pendingChildren[replicaId] then
		for _, child in self._pendingChildren[replicaId] do
			child._parentId = replicaId
			child._parent = replica
			table.insert(replica._children, child)
		end
		self._pendingChildren[replicaId] = nil
	end

	-- Fire creation signal
	self.ReplicaCreated:Fire(replica)
end

--[[
  Handle data update from server
  @param replicaId string - ID of the replica to update
  @param path string - Data path to update
  @param value any - New value
]]
function ReplicaController:_handleReplicaUpdate(replicaId, path, value)
	local replica = self._replicasById[replicaId]
	if replica then
		replica:_handleDataUpdate(path, value)
	end
end

--[[
  Handle array insertion from server
  @param replicaId string - ID of the replica
  @param path string - Path to the array
  @param index number - Index to insert at
  @param value any - Value to insert
]]
function ReplicaController:_handleReplicaArrayInsert(replicaId, path, index, value)
	local replica = self._replicasById[replicaId]
	if replica then
		replica:_handleArrayInsert(path, index, value)
	end
end

--[[
  Handle array removal from server
  @param replicaId string - ID of the replica
  @param path string - Path to the array
  @param index number - Index to remove
]]
function ReplicaController:_handleReplicaArrayRemove(replicaId, path, index)
	local replica = self._replicasById[replicaId]
	if replica then
		replica:_handleArrayRemove(path, index)
	end
end

--[[
  Handle parent change from server
  @param replicaId string - ID of the replica
  @param parentId string? - New parent ID or nil
]]
function ReplicaController:_handleReplicaSetParent(replicaId, parentId)
	local replica = self._replicasById[replicaId]
	if replica then
		-- Remove from old parent's children list
		if replica._parent then
			local children = replica._parent._children
			for i, child in ipairs(children) do
				if child == replica then
					table.remove(children, i)
					break
				end
			end
		end

		-- Set new parent
		if parentId then
			local parent = self._replicasById[parentId]
			if parent then
				replica._parent = parent
				table.insert(parent._children, replica)
			else
				-- Parent doesn't exist yet
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

--[[
  Handle replica destruction from server
  @param replicaId string - ID of the replica to destroy
]]
function ReplicaController:_handleReplicaDestroy(replicaId)
	local replica = self._replicasById[replicaId]
	if not replica then return end

	-- Remove from ID map
	self._replicasById[replicaId] = nil

	-- Remove from tag maps
	for tag, replicas in self._replicasByTag do
		for i, r in replicas do
			if r:GetId() == replicaId then
				table.remove(replicas, i)
				break
			end
		end
	end

	-- Clear parent reference
	if replica._parent then
		local children = replica._parent._children
		for i, child in ipairs(children) do
			if child == replica then
				table.remove(children, i)
				break
			end
		end
	end

	-- Clear pending children
	self._pendingChildren[replicaId] = nil

	-- Fire destroyed signal
	self.ReplicaDestroyed:Fire(replicaId, replica._tags)
end

--[[
  Get a specific replica by its ID
  @param replicaId string - ID of the replica to find
  @return Replica? - The replica if found, nil otherwise
]]
function ReplicaController:GetReplicaById(replicaId)
	return self._replicasById[replicaId]
end

--[[
  Get all replicas that have all the specified tags
  @param tags {string} - Array of tags to filter by
  @return {Replica} - Array of matching replicas
]]
function ReplicaController:GetReplicasWithTags(tags: {string}): {Replica}
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
  Wait for a replica with all the specified tags
  @param tags {string} - Array of tags to filter by
  @param timeout number? - Optional timeout in seconds (default: 10)
  @return Replica? - First matching replica or nil if timed out
]]
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

	return nil -- timed out
end

--[[
  Find the first replica that matches a predicate function
  @param predicate function - Function that takes a replica and returns boolean
  @param timeout number? - Optional timeout in seconds (default: 10)
  @return Replica? - First matching replica or nil if timed out
]]
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

	return nil -- timed out
end

--[[
  Request initial data from the server
  @return self
]]
function ReplicaController:RequestData()
	assert(self._isInitialized, "ReplicaController must be initialized before requesting data")

	self._remote:FireServer("RequestData")
	return self
end

return ReplicaController
