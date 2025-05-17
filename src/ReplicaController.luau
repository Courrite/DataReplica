local RunService = game:GetService("RunService")

local isServer = RunService:IsServer()

local ReplicaService
local Signal = require(script.Parent.Signal)

local Replica = {}
Replica.__index = Replica

function Replica.new(id: string, tags: {string}, dataTable: {[string]: any}, token: any?)
	-- creates a new replica instance with specified properties
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
	
	self.Changed = Signal.new() -- path, replica
	self.Destroyed = Signal.new() -- token, replicaId

	if isServer then
		self._token = token

		if not ReplicaService then
			ReplicaService = require(script.Parent.Parent.ReplicaService)
		end
	end

	if not isServer then
		self._signals = {}
		self._listeners = {}
	end

	return self
end

function Replica:GetId()
	-- returns the replica's unique id
	return self._id
end

function Replica:GetTags()
	-- returns the replica's tags
	return self._tags
end

function Replica:GetParent()
	-- returns the replica's parent replica
	return self._parent
end

function Replica:GetParentId()
	-- returns the replica's parent id
	return self._parentId
end

function Replica:GetChildren()
	-- returns the replica's children
	return self._children
end

local function deepCopy(original)
	-- creates a deep copy of a table
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
	-- gets a value at specified path in a table
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
	-- sets a value at specified path in a table
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

if isServer then
	function Replica:SetValue(path, value)
		-- sets a value at specified path and replicates to clients
		assert(self._token, "Replica token required for write operations")

		setValueAtPath(self.Data, path, value)

		ReplicaService:_replicaUpdateHandler(self._token, "update", path, value)

		return value
	end

	function Replica:ArrayInsert(arrayPath, index, value)
		-- inserts a value into an array at specified path and replicates to clients
		assert(self._token, "Replica token required for write operations")

		local array = getValueAtPath(self.Data, arrayPath)
		assert(typeof(array) == "table", "Path does not point to a table: " .. arrayPath)

		if index then
			table.insert(array, index, value)
		else
			table.insert(array, value)
			index = #array
		end

		ReplicaService:_replicaUpdateHandler(self._token, "arrayInsert", arrayPath, index, value)

		return index
	end

	function Replica:ArrayRemove(arrayPath, index)
		-- removes a value from an array at specified path and replicates to clients
		assert(self._token, "Replica token required for write operations")

		local array = getValueAtPath(self.Data, arrayPath)
		assert(typeof(array) == "table", "Path does not point to a table: " .. arrayPath)

		local value = array[index]

		table.remove(array, index)

		ReplicaService:_replicaUpdateHandler(self._token, "arrayRemove", arrayPath, index)

		return value
	end

	function Replica:SetParent(parentReplica)
		-- sets the parent of this replica and replicates to clients
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
		-- destroys this replica and its children
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

if not isServer then
	function Replica:_handleDataUpdate(path, value)
		-- handles data update from server
		setValueAtPath(self.Data, path, value)

		local parts = string.split(path, ".")
		local currentPath = ""

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

		if self._listeners["update"] then
			for _, callback in ipairs(self._listeners["update"]) do
				task.spawn(callback, path, value)
			end
		end
		

		self.Changed:Fire(path, self)
	end

	function Replica:_handleArrayInsert(path, index, value)
		-- handles array insert from server
		local array = getValueAtPath(self.Data, path)

		if typeof(array) ~= "table" then
			array = {}
			setValueAtPath(self.Data, path, array)
		end

		table.insert(array, index, value)

		if self._signals[path] then
			for _, callback in ipairs(self._signals[path]) do
				task.spawn(callback, array)
			end
		end

		if self._listeners["arrayChange"] then
			for _, callback in ipairs(self._listeners["arrayChange"]) do
				task.spawn(callback, path, "insert", index, value)
			end
		end
		
		self.Changed:Fire(path, self)
	end

	function Replica:_handleArrayRemove(path, index)
		-- handles array remove from server
		local array = getValueAtPath(self.Data, path)

		if typeof(array) == "table" then
			table.remove(array, index)

			if self._signals[path] then
				for _, callback in ipairs(self._signals[path]) do
					task.spawn(callback, array)
				end
			end

			if self._listeners["arrayChange"] then
				for _, callback in ipairs(self._listeners["arrayChange"]) do
					task.spawn(callback, path, "remove", index)
				end
			end
		end
		
		self.Changed:Fire(path, self)
	end

	function Replica:_handleSetParent(parentId)
		-- handles parent change from server
		self._parentId = parentId

		if self._listeners["parentChange"] then
			for _, callback in ipairs(self._listeners["parentChange"]) do
				task.spawn(callback, parentId)
			end
		end
	end
end

return Replica
