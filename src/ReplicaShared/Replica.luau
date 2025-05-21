local RunService = game:GetService("RunService")

local isServer = RunService:IsServer()

local ReplicaService
local Signal = require(script.Parent.Signal)

local Replica = {}
Replica.__index = Replica

function Replica.new(id: string, tags: {string}, dataTable: {[string]: any}, token: any?)
	-- Creates a new replica instance with specified properties
	assert(typeof(id) == "string", "Replica ID must be a string")
	assert(typeof(tags) == "table", "Replica tags must be a table")
	assert(typeof(dataTable) == "table", "Replica data must be a table")

	if isServer then
		assert(token ~= nil, "Replica token is required on server")
	end

	local self = setmetatable({}, Replica)

	self._id = id
	self._tags = tags
	self.Data = dataTable
	self._children = {}
	self._parent = nil
	self._parentId = nil

	self.Changed = Signal.new() -- Fires when data changes (path, replica)
	self.Destroyed = Signal.new() -- Fires when replica is destroyed (token, replicaId)

	if isServer then
		self._token = token

		if not ReplicaService then
			ReplicaService = require(script.Parent.Parent.ReplicaService)
		end
	end

	if not isServer then
		self._signals = {} -- Path-based signals for specific data changes
		self._listeners = {} -- Event listeners for specific actions
	end

	return self
end

function Replica:GetId()
	-- Returns the replica's unique id
	return self._id
end

function Replica:GetTags()
	-- Returns the replica's tags
	return self._tags
end

function Replica:HasTag(tag)
	-- Checks if the replica has a specific tag
	for _, replicaTag in ipairs(self._tags) do
		if replicaTag == tag then
			return true
		end
	end
	return false
end

function Replica:GetParent()
	-- Returns the replica's parent replica
	return self._parent
end

function Replica:GetParentId()
	-- Returns the replica's parent id
	return self._parentId
end

function Replica:GetChildren()
	-- Returns the replica's children
	return self._children
end

-- Utility functions for data manipulation
local function deepCopy(original)
	-- Creates a deep copy of a table
	local copy = {}
	for k, v in original do
		if type(v) == "table" then
			copy[k] = deepCopy(v)
		else
			copy[k] = v
		end
	end
	return copy
end

local function getValueAtPath(tbl, path)
	-- Gets a value at specified path in a table
	local current = tbl
	local pathParts = string.split(path, ".")

	for i, key in ipairs(pathParts) do
		if i < #pathParts then
			if typeof(current) ~= "table" then
				return nil
			end
			current = current[key]
		else
			return current[key]
		end
	end

	return nil
end

local function setValueAtPath(tbl, path, value)
	-- Sets a value at specified path in a table
	local current = tbl
	local pathParts = string.split(path, ".")

	for i, key in ipairs(pathParts) do
		if tonumber(key) then
			key = tonumber(key)
		end

		if i < #pathParts then
			if current[key] == nil or typeof(current[key]) ~= "table" then
				current[key] = {}
			end
			current = current[key]
		else
			current[key] = value
		end
	end

	return value
end

-- Server-side methods
if isServer then
	function Replica:SetValue(path, value)
		-- Sets a value at specified path and replicates to clients
		assert(self._token, "Replica token required for write operations")

		setValueAtPath(self.Data, path, value)

		ReplicaService:_replicaUpdateHandler(self._token, "update", path, value)

		return value
	end

	function Replica:ArrayInsert(arrayPath, index, value)
		-- Inserts a value into an array at specified path and replicates to clients
		assert(self._token, "Replica token required for write operations")

		local array = getValueAtPath(self.Data, arrayPath)
		assert(typeof(array) == "table", "Path does not point to a table: " .. arrayPath)

		if index then
			array[index] = value
		else
			table.insert(array, value)
			index = #array
		end

		ReplicaService:_replicaUpdateHandler(self._token, "arrayInsert", arrayPath, index, value)

		return index
	end

	function Replica:ArrayRemove(arrayPath, index)
		-- Removes a value from an array at specified path and replicates to clients
		assert(self._token, "Replica token required for write operations")

		local array = getValueAtPath(self.Data, arrayPath)
		assert(typeof(array) == "table", "Path does not point to a table: " .. arrayPath)

		local value = array[index]

		table.remove(array, index)

		ReplicaService:_replicaUpdateHandler(self._token, "arrayRemove", arrayPath, index)

		return value
	end

	function Replica:SetParent(parentReplica)
		-- Sets the parent of this replica and replicates to clients
		assert(self._token, "Replica token required for write operations")

		if self._parent then
			local oldParent = self._parent
			for i, child in ipairs(oldParent._children) do
				if child == self then
					table.remove(oldParent._children, i)
					break
				end
			end
		end

		self._parent = parentReplica
		self._parentId = parentReplica and parentReplica:GetId() or nil

		if parentReplica then
			table.insert(parentReplica._children, self)
		end

		ReplicaService:_replicaUpdateHandler(self._token, "setParent", "", self._parentId)
	end

	function Replica:Destroy()
		-- Destroys this replica and its children
		assert(self._token, "Replica token required for write operations")

		if self._parent then
			self:SetParent(nil)
		end

		for _, child in ipairs(self._children) do
			child:Destroy()
		end

		ReplicaService:DestroyReplica(self)
	end
end

-- Client-side methods
if not isServer then
	function Replica:_handleDataUpdate(path, value)
		-- Handles data update from server
		setValueAtPath(self.Data, path, value)

		local parts = string.split(path, ".")
		local currentPath = ""

		-- Trigger signals for each path segment
		for i, part in ipairs(parts) do
			if i > 1 then
				currentPath = currentPath .. "."
			end
			currentPath = currentPath .. part

			if self._signals[currentPath] then
				for _, callback in ipairs(self._signals[currentPath]) do
					task.spawn(callback, getValueAtPath(self.Data, currentPath))
				end
			end
		end

		-- Trigger general update listeners
		if self._listeners["update"] then
			for _, callback in ipairs(self._listeners["update"]) do
				task.spawn(callback, path, value)
			end
		end

		-- Fire change signal
		self.Changed:Fire(path, self)
	end

	function Replica:_handleArrayInsert(path, index, value)
		-- Handles array insert from server
		local array = getValueAtPath(self.Data, path)

		if typeof(array) ~= "table" then
			array = {}
			setValueAtPath(self.Data, path, array)
		end

		if index then
			array[index] = value
		else
			table.insert(array, value)
		end

		-- Trigger path-specific signals
		if self._signals[path] then
			for _, callback in ipairs(self._signals[path]) do
				task.spawn(callback, array)
			end
		end

		-- Trigger array change listeners
		if self._listeners["arrayChange"] then
			for _, callback in ipairs(self._listeners["arrayChange"]) do
				task.spawn(callback, path, "insert", index, value)
			end
		end

		-- Fire change signal
		self.Changed:Fire(path, self)
	end

	function Replica:_handleArrayRemove(path, index)
		-- Handles array remove from server
		local array = getValueAtPath(self.Data, path)

		if typeof(array) == "table" then
			table.remove(array, index)

			-- Trigger path-specific signals
			if self._signals[path] then
				for _, callback in ipairs(self._signals[path]) do
					task.spawn(callback, array)
				end
			end

			-- Trigger array change listeners
			if self._listeners["arrayChange"] then
				for _, callback in ipairs(self._listeners["arrayChange"]) do
					task.spawn(callback, path, "remove", index)
				end
			end
		end

		-- Fire change signal
		self.Changed:Fire(path, self)
	end

	function Replica:_handleSetParent(parentId)
		-- Handles parent change from server
		self._parentId = parentId

		-- Trigger parent change listeners
		if self._listeners["parentChange"] then
			for _, callback in ipairs(self._listeners["parentChange"]) do
				task.spawn(callback, parentId)
			end
		end
	end

	function Replica:OnChange(path, callback)
		-- Register a callback for when a specific path changes
		if not self._signals[path] then
			self._signals[path] = {}
		end

		table.insert(self._signals[path], callback)
	end

	function Replica:ListenForChanges(changeType, callback)
		-- Register a callback for a specific change type (update, arrayChange, parentChange)
		if not self._listeners[changeType] then
			self._listeners[changeType] = {}
		end

		table.insert(self._listeners[changeType], callback)
	end
end

return Replica
