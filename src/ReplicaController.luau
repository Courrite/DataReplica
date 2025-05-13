local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

assert(RunService:IsClient(), "ReplicaController can only be required by the client")

local ReplicaClass = require(script.Parent.ReplicaShared.Replica)
local Remote = require(script.Parent.ReplicaShared.Remote)

local ReplicaController = {
	_replicasById = {}, -- Map of replicas by their unique ID
	_replicasByTag = {}, -- Map of replicas organized by tag
	_replicasByTemplate = {}, -- Map of replicas organized by template
	_pendingChildren = {}, -- Children waiting for parents to be created
	_isInitialized = false,
	_remote = nil -- remote instance
}

function ReplicaController:Initialize()
	if self._isInitialized then
		warn("ReplicaController has already been initialized")
		return self
	end

	-- initialize the Remote class with custom names
	self._remote = Remote.new("ReplicaEvent")

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

function ReplicaController:_handleReplicaCreate(replicaId, template, tags, data, parentId)
	local replica = ReplicaClass.new(replicaId, template, tags, data)

	self._replicasById[replicaId] = replica

	for _, tag in ipairs(tags) do
		if not self._replicasByTag[tag] then
			self._replicasByTag[tag] = {}
		end
		table.insert(self._replicasByTag[tag], replica)
	end

	if not self._replicasByTemplate[template] then
		self._replicasByTemplate[template] = {}
	end
	table.insert(self._replicasByTemplate[template], replica)

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
		if replica._parent then
			local children = replica._parent._children
			for i, child in ipairs(children) do
				if child == replica then
					table.remove(children, i)
					break
				end
			end
		end

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

	self._replicasById[replicaId] = nil

	for tag, replicas in pairs(self._replicasByTag) do
		for i, r in ipairs(replicas) do
			if r:GetId() == replicaId then
				table.remove(replicas, i)
				break
			end
		end
	end

	local template = replica:GetTemplate()
	if self._replicasByTemplate[template] then
		for i, r in ipairs(self._replicasByTemplate[template]) do
			if r:GetId() == replicaId then
				table.remove(self._replicasByTemplate[template], i)
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
end

-- public methods
-- Get a specific replica by ID
function ReplicaController:GetReplicaById(replicaId)
	return self._replicasById[replicaId]
end

-- Get all replicas with a specific tag
function ReplicaController:GetReplicasWithTag(tag)
	return self._replicasByTag[tag] or {}
end

-- Get all replicas with a specific template
function ReplicaController:GetReplicasWithTemplate(template)
	return self._replicasByTemplate[template] or {}
end

-- Utility functions for waiting for replicas
function ReplicaController:WaitForReplicaWithTag(tag, timeout)
	timeout = timeout or 10
	local startTime = os.clock()

	while os.clock() - startTime < timeout do
		local replicas = self:GetReplicasWithTag(tag)
		if #replicas > 0 then
			return replicas[1]
		end
		task.wait(0.1)
	end

	return nil -- timed out
end

function ReplicaController:WaitForReplicaWithTemplate(template, timeout)
	timeout = timeout or 10
	local startTime = os.clock()

	while os.clock() - startTime < timeout do
		local replicas = self:GetReplicasWithTemplate(template)
		if #replicas > 0 then
			return replicas[1]
		end
		task.wait(0.1)
	end

	return nil -- timed out
end

function ReplicaController:FindFirstReplicaWithPredicate(predicate, timeout)
	assert(typeof(predicate) == "function", "Predicate must be a function")

	timeout = timeout or 10
	local startTime = os.clock()

	while os.clock() - startTime < timeout do
		for _, replica in pairs(self._replicasById) do
			if predicate(replica) then
				return replica
			end
		end
		task.wait(0.1)
	end

	return nil -- timed out
end

return ReplicaController
