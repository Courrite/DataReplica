local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remote = {}
Remote.__index = Remote

local FOLDER_NAME = "ReplicaRemotes"
local MAX_RETRY_ATTEMPTS = 2
local RETRY_DELAY = 1

-- static registry to prevent duplicates with the same name
Remote._registry = {}

function Remote.new(eventName)
	-- use unique key based on folder and event name
	local remoteKey = FOLDER_NAME .. "/" .. eventName

	if Remote._registry[remoteKey] then
		return Remote._registry[remoteKey]
	end

	local self = setmetatable({}, Remote)
	self._handlers = {}
	self._isServer = RunService:IsServer()
	self._eventName = eventName
	self._folderName = FOLDER_NAME
	self._setupAttempts = 0

	-- setup appropriate environment
	if self._isServer then
		self:_setupServer()
	else
		self:_setupClient()
	end

	-- register to avoid duplicates
	Remote._registry[remoteKey] = self

	return self
end

function Remote:_getOrCreateFolder()
	local folder = ReplicatedStorage:FindFirstChild(self._folderName)

	if not folder and self._isServer then
		-- server creates folder if it doesn't exist
		folder = Instance.new("Folder")
		folder.Name = self._folderName
		folder.Parent = ReplicatedStorage
	elseif not folder then
		-- client waits for folder from server with retry logic
		folder = ReplicatedStorage:FindFirstChild(self._folderName)
		if not folder then
			for attempt = 1, MAX_RETRY_ATTEMPTS do
				print("Waiting for RemoteEvent folder (attempt " .. attempt .. "/" .. MAX_RETRY_ATTEMPTS .. "): " .. self._folderName)
				folder = ReplicatedStorage:WaitForChild(self._folderName, 2)
				if folder then
					break
				end

				if attempt == MAX_RETRY_ATTEMPTS then
					error("Failed to find RemoteEvent folder after " .. MAX_RETRY_ATTEMPTS .. " attempts: " .. self._folderName)
				end

				task.wait(RETRY_DELAY)
			end
		end
	end

	return folder
end

function Remote:_setupServer()
	local remoteFolder = self:_getOrCreateFolder()

	-- create or use existing RemoteEvent
	local existingRemote = remoteFolder:FindFirstChild(self._eventName)
	if existingRemote and existingRemote:IsA("RemoteEvent") then
		self._remoteEvent = existingRemote
	else
		self._remoteEvent = Instance.new("RemoteEvent")
		self._remoteEvent.Name = self._eventName
		self._remoteEvent.Parent = remoteFolder
	end

	-- connect to RemoteEvent
	self._remoteEvent.OnServerEvent:Connect(function(player, action, ...)
		if self._handlers[action] then
			local args = {...}
			
			task.spawn(self._handlers[action], player, table.unpack(args))
		end
	end)
end

function Remote:_setupClient()
	local success, result = pcall(function()
		local remoteFolder = self:_getOrCreateFolder()

		-- retry logic for waiting for the RemoteEvent
		local remote
		for attempt = 1, MAX_RETRY_ATTEMPTS do
			remote = remoteFolder:WaitForChild(self._eventName, 2)
			if remote then
				break
			end

			if attempt == MAX_RETRY_ATTEMPTS then
				return false
			end

			task.wait(RETRY_DELAY)
		end

		self._remoteEvent = remote

		-- connect to RemoteEvent
		self._remoteEvent.OnClientEvent:Connect(function(action, ...)
			if self._handlers[action] then
				task.spawn(self._handlers[action], ...)
			end
		end)

		return true
	end)

	if not success then
		warn("Failed to setup client remote: " .. tostring(result))

		-- retry setup after a delay
		self._setupAttempts += 1
		if self._setupAttempts <= MAX_RETRY_ATTEMPTS then
			warn("Retrying setup in " .. RETRY_DELAY .. " seconds (attempt " .. self._setupAttempts .. "/" .. MAX_RETRY_ATTEMPTS .. ")")
			task.delay(RETRY_DELAY, function()
				self:_setupClient()
			end)
		else
			error("Failed to setup client remote after " .. MAX_RETRY_ATTEMPTS .. " attempts: " .. tostring(result))
		end
	end
end

-- Register a handler for a specific action
function Remote:RegisterHandler(action, handler)
	assert(type(action) == "string", "Action must be a string")
	assert(type(handler) == "function", "Handler must be a function")

	self._handlers[action] = handler
end

function Remote:FireClient(player, action, ...)
	assert(self._isServer, "FireClient can only be called from the server")
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Invalid player")

	local args = {...}
	if self._remoteEvent then
		self._remoteEvent:FireClient(player, action, table.unpack(args))
	else
		warn("Attempted to FireClient before RemoteEvent was ready")
	end
end

function Remote:FireAllClients(action, ...)
	assert(self._isServer, "FireAllClients can only be called from the server")

	local args = {...}
	if self._remoteEvent then
		self._remoteEvent:FireAllClients(action, table.unpack(args))
	else
		warn("Attempted to FireAllClients before RemoteEvent was ready")
	end
end

function Remote:FireClients(players, action, ...)
	assert(self._isServer, "FireClients can only be called from the server")
	assert(type(players) == "table", "Players must be a table")

	local args = {...}
	if not self._remoteEvent then
		warn("Attempted to FireClients before RemoteEvent was ready")
		return
	end

	for _, ply in ipairs(players) do
		if typeof(ply) == "Instance" and ply:IsA("Player") then
			self._remoteEvent:FireClient(ply, action, table.unpack(args))
		end
	end
end

function Remote:FireServer(action, ...)
	assert(not self._isServer, "FireServer can only be called from the client")

	local args = {...}
	if self._remoteEvent then
		self._remoteEvent:FireServer(action, table.unpack(args))
	else
		warn("Attempted to FireServer before RemoteEvent was ready: " .. action)
		task.delay(RETRY_DELAY, function()
			if self._remoteEvent then
				self._remoteEvent:FireServer(action, table.unpack(args))
			else
				warn("Still unable to FireServer after delay: " .. action)
			end
		end)
	end
end


return Remote
