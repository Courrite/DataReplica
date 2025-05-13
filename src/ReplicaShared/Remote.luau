local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remote = {}
Remote.__index = Remote

local FOLDER_NAME = "GameRemotes"

-- static registry of remotes to prevent duplicates with the same name
Remote._registry = {}

function Remote.new(eventName)
	-- check if this remote already exists in our registry
	local remoteKey = FOLDER_NAME .. "/" .. eventName
	if Remote._registry[remoteKey] then
		return Remote._registry[remoteKey]
	end

	local self = setmetatable({}, Remote)
	self._handlers = {}
	self._isServer = RunService:IsServer()
	self._eventName = eventName
	self._folderName = FOLDER_NAME

	if self._isServer then
		self:_setupServer()
	else
		self:_setupClient()
	end

	-- register this remote to avoid duplicates
	Remote._registry[remoteKey] = self

	return self
end

function Remote:_getOrCreateFolder()
	-- get or create the remote folder
	local folder = ReplicatedStorage:FindFirstChild(self._folderName)

	if not folder and self._isServer then
		folder = Instance.new("Folder")
		folder.Name = self._folderName
		folder.Parent = ReplicatedStorage
	elseif not folder then
		folder = ReplicatedStorage:WaitForChild(self._folderName)
	end

	return folder
end

function Remote:_setupServer()
	-- get or create remote folder
	local remoteFolder = self:_getOrCreateFolder()

	-- create the remote event
	self._remoteEvent = Instance.new("RemoteEvent")
	self._remoteEvent.Name = self._eventName
	self._remoteEvent.Parent = remoteFolder

	-- connect to remote event
	self._remoteEvent.OnServerEvent:Connect(function(player, action, ...)
		if self._handlers[action] then
			self._handlers[action](player, ...)
		end
	end)
end

function Remote:_setupClient()
	-- find remote event on the client
	local remoteFolder = self:_getOrCreateFolder()
	self._remoteEvent = remoteFolder:WaitForChild(self._eventName)

	-- connect to remote event
	self._remoteEvent.OnClientEvent:Connect(function(action, ...)
		if self._handlers[action] then
			self._handlers[action](...)
		end
	end)
end

-- Register a handler for a specific action
function Remote:RegisterHandler(action, handler)
	assert(type(action) == "string", "Action must be a string")
	assert(type(handler) == "function", "Handler must be a function")

	self._handlers[action] = handler
end

-- Fire an event from server to client
function Remote:FireClient(player, action, ...)
	assert(self._isServer, "FireClient can only be called from the server")
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Invalid player")

	self._remoteEvent:FireClient(player, action, ...)
end

-- Fire an event from server to all clients
function Remote:FireAllClients(action, ...)
	assert(self._isServer, "FireAllClients can only be called from the server")

	self._remoteEvent:FireAllClients(action, ...)
end

-- Fire an event from server to multiple clients
function Remote:FireClients(players, action, ...)
	assert(self._isServer, "FireClients can only be called from the server")
	assert(type(players) == "table", "Players must be a table")

	for _, player in ipairs(players) do
		self._remoteEvent:FireClient(player, action, ...)
	end
end

-- Fire an event from client to server
function Remote:FireServer(action, ...)
	assert(not self._isServer, "FireServer can only be called from the client")

	self._remoteEvent:FireServer(action, ...)
end

return Remote
