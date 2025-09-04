local bit = require("bit")
local ffi = require("ffi")
local log = require("log")
local cloneloader = require("memory.cloneloader")
local process = require("memory." .. jit.os:lower())
local notification = require("notification")

require("extensions.string")
require("extensions.table")

local NULL = 0x00000000

local GAME_ID_ADDR  = 0x80000000
local GAME_VER_ADDR = 0x80000007
local GAME_ID_LEN   = 0x06
local GAME_NONE     = "\0\0\0\0\0\0"

local VC_ID_ADDR    = 0x80003180
local VC_ID_LEN     = 0x04
local VC_NONE       = "\0\0\0\0"

local memory = {
	clones = require("games.clones"),
	vcclones = require("games.vcclones"),

	gameid = GAME_NONE,
	vcid = VC_NONE,
	process = process,
	permissions = process:hasPermissions(),

	hooked = false,
	initialized = false,
	ingame = false,

	map = {},
	values = {},

	hooks = {},
	wildcard_hooks = {},

	hook_queue = {},
}

cloneloader.loadFile("clones.lua", memory.clones)

setmetatable(memory, {__index = memory.values})

local bswap = bit.bswap
local function bswap16(n)
	return bit.bor(bit.rshift(n, 8), bit.lshift(bit.band(n, 0xFF), 8))
end

local function sanitizeId(id, expectedLen, noneValue)
	if not id or #id ~= expectedLen then
		return noneValue
	end
	-- Normalize to ASCII uppercase without touching non-ASCII bytes
	local upper = id:upper()
	-- Validate: only A-Z and 0-9 are allowed in IDs
	if not upper:match("^[A-Z0-9]+$") then
		return noneValue
	end
	return upper
end

function memory.readGameID()
	local gid = memory.read(GAME_ID_ADDR, GAME_ID_LEN)
	-- Filter known false-positives first
	if gid and #gid >= 4 and gid:sub(1, 4) == "nvph" then
		return GAME_NONE
	end
	return sanitizeId(gid, GAME_ID_LEN, GAME_NONE)
end

function memory.readVirtualConsoleID()
	local vcid = memory.read(VC_ID_ADDR, VC_ID_LEN)
	return sanitizeId(vcid, VC_ID_LEN, VC_NONE)
end

function memory.readGameVersion()
	return memory.readUByte(GAME_VER_ADDR)
end

local typecache = {}

local function cache(typ, len)
	-- This stops us from constantly calling ffi.new by recycling old variables
	len = len or 1
	if not typecache[typ] then
		-- Create new cache for this type
		typecache[typ] = {}
	elseif typecache[typ][len] then
		-- Set the cached value to all 0's so it can be reused safely
		ffi.fill(typecache[typ][len], len)
		-- Return the cached value
		return typecache[typ][len]
	end
	-- Create a new variable
	local cached = ffi.new(string.format("%s[?]", typ), len)
	-- Store it in the cache
	typecache[typ][len] = cached
	return cached
end

function memory.read(addr, len)
	if not process:hasProcess() then
		return string.rep("\0", len)
	end
	local output = cache("uint8_t", len)
	local size = ffi.sizeof(output)
	process:read(addr, output, size)
	return ffi.string(output, size)
end

function memory.readByte(addr)
	if not process:hasProcess() then return 0 end
	local output = cache("int8_t")
	process:read(addr, output, ffi.sizeof(output))
	return output[0]
end

function memory.writeByte(addr, value)
	if not process:hasProcess() then return end
	local input = cache("int8_t")
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readBool(addr)
	if not process:hasProcess() then return false end
	return memory.readByte(addr) == 1
end

function memory.writeBool(addr, value)
	if not self:hasProcess() then return end
	self:writeByte(addr, value == true and 1 or 0)
end

function memory.readUByte(addr)
	if not process:hasProcess() then return 0 end
	local output = cache("uint8_t")
	process:read(addr, output, ffi.sizeof(output))
	return output[0]
end

function memory.writeUByte(addr, value)
	if not process:hasProcess() then return end
	local input = cache("uint8_t")
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readShort(addr)
	if not process:hasProcess() then return 0 end
	local output = cache("int16_t")
	process:read(addr, output, ffi.sizeof(output))
	return bswap16(output[0])
end

function memory.writeShort(addr, value)
	if not process:hasProcess() then return end
	local input = cache("int16_t")
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readUShort(addr)
	if not process:hasProcess() then return 0 end
	local output = cache("uint16_t")
	process:read(addr, output, ffi.sizeof(output))
	return bswap16(output[0])
end

function memory.writeUShort(addr, value)
	if not process:hasProcess() then return end
	local input = cache("uint16_t")
	return process:write(addr, input, ffi.sizeof(input))
end

do
	local floatconversion = ffi.new("union { uint32_t i; float f; }")

	function memory.readFloat(addr)
		if not process:hasProcess() then return 0 end
		local output = cache("uint32_t")
		process:read(addr, output, ffi.sizeof(output))
		floatconversion.i = bswap(output[0])
		return floatconversion.f, floatconversion.i
	end
end

function memory.writeFloat(addr, value)
	if not process:hasProcess() then return end
	local input = cache("float")
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readInt(addr)
	if not process:hasProcess() then return 0 end
	local output = cache("int32_t")
	process:read(addr, output, ffi.sizeof(output))
	return bswap(output[0])
end

function memory.writeInt(addr, value)
	if not process:hasProcess() then return end
	local input = cache("int32_t")
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readUInt(addr)
	if not process:hasProcess() then return 0 end
	local output = cache("uint32_t")
	process:read(addr, output, ffi.sizeof(output))
	return bswap(output[0])
end

function memory.writeUInt(addr, value)
	if not process:hasProcess() then return end
	local input = cache("uint32_t")
	return process:write(addr, input, ffi.sizeof(input))
end

local char_replacement_map = {
	[0x8149] = "!", [0x8168] = "\"", [0x8194] = "#", [0x8190] = "$",
	[0x8193] = "%", [0x8195] = "&", [0x8166] = "'", [0x8169] = "(",
	[0x816A] = ")", [0x8196] = "*", [0x817B] = "+", [0x8143] = ",",
	[0x817C] = "-", [0x8144] = ".", [0x815E] = "/", [0x8146] = ":",
	[0x8147] = ";", [0x8183] = "<", [0x8181] = "=", [0x8184] = ">",
	[0x8148] = "?", [0x8197] = "@", [0x816D] = "[", [0x815F] = "\\",
	[0x816E] = "]", [0x814F] = "^", [0x8151] = "_", [0x814D] = "`",
	[0x816F] = "{", [0x8162] = "|", [0x8170] = "}", [0x8160] = "~",
}

local function convertJisStr(str)
	local niceStr = ""
	local i = 1
	while i <= #str do
		local c1 = string.sub(str, i, i)
		local b1 = string.byte(c1)
		if b1 then
			if bit.band(b1, 0x80) == 0x80 then
				local c2 = string.sub(str, i + 1, i + 1)
				local b2 = string.byte(c2)

				local b16 = bit.bor(bit.lshift(b1, 8), bit.lshift(b2, 0))

				if char_replacement_map[b16] then
					niceStr = niceStr .. char_replacement_map[b16]
				end

				i = i + 2
			else
				niceStr = niceStr .. c1
				i = i + 1
			end
		end
	end
	return niceStr
end

-- Captures all characters up to any amount of NULL characters
local STRING_PATTERN = "^(.-)%z-$"

local TYPES_READ = {
	["bool"] = memory.readBool,

	["sbyte"] = memory.readByte,
	["byte"] = memory.readUByte,
	["short"] = memory.readShort,
	["int"] = memory.readInt,

	["u8"] = memory.readUByte,
	["s8"] = memory.readByte,
	["u16"] = memory.readUShort,
	["s16"] = memory.readShort,
	["u32"] = memory.readUInt,
	["s32"] = memory.readInt,

	["float"] = memory.readFloat,

	["data"] = memory.read,
	["string"] = function(addr, len)
		local value = memory.read(addr, len)
		return value:match(STRING_PATTERN)
	end,
	["string-jis"] = function(addr, len)
		local value = memory.read(addr, len)
		return convertJisStr(value:match(STRING_PATTERN) or value)
	end,
}

-- Creates or updates a tree of values for easy indexing
-- Example a path of "player.name" will become memory.players = { name = value }
function memory.cacheValue(table, path, value)
	local last = table
	local last_key = nil

	local keys = {}
	for key in string.gmatch(path, "[^%.]+") do
		keys[#keys + 1] = tonumber(key) or key
	end

	for i, key in ipairs(keys) do
		if i < #keys then
			last[key] = last[key] or {}
			last = last[key]
		else
			if type(last) ~= "table" then
				return error(("Failed to index a %s value (%q)"):format(type(last), keys[i-1]))
			end
			last[key] = value
			last_key = key
		end
	end

	-- Return the table that the value is being stored in, and the key name
	return last, last_key
end

local ADDRESS = {}
ADDRESS.__index = ADDRESS

function memory.newvalue(addr, offset, struct, name)
	assert(type(addr) == "number", "argument #1 'address' must be a number")
	assert(TYPES_READ[struct.type] ~= nil, "unhandled type: " .. struct.type)

	name = name or struct.name or addr

	local init = struct.init or NULL

	-- create/get a new value cache based off of the value name
	local tbl, key = memory.cacheValue(memory.values, name, init)

	log.trace("[MEMORY] VALUE CACHE %08X + %X %q", addr, offset, name)

	--local shoulddebug = name ~= "frame" and name:sub(1,10) ~= "controller"

	return setmetatable({
		name = name,

		address = addr, -- Where in memory this value is located
		offset = offset, -- How far past the address value we should get the value from

		type = struct.type,
		-- Assign the function we will be using to read from memory
		read = TYPES_READ[struct.type],
		len = struct.len,

		-- Setup the cache
		cache = tbl,
		cache_key = key,
		cache_value = init,

		debug = struct.debug,
	}, ADDRESS)
end

function ADDRESS:update()
	if self.address == NULL then return end

	local address = self.address + self.offset

	-- value = converted value
	-- orig = Non-converted value (Only available for floats)
	local value, orig = self.read(address, self.len)

	-- Check if there has been a value change
	if self.cache_value ~= value then
		self.cache_value = value
		self.cache[self.cache_key] = self.cache_value

		if self.debug then
			if self.type == "string" or self.type == "string-jis" or self.type == "data" then
				log.debug("[MEMORY] [0x%08X  = 0x%s] %s = %q", address, string.tohex(value), self.name, value)
			else
				local numValue = tonumber(orig) or tonumber(value) or (value and 1 or 0)
				log.debug("[MEMORY] [0x%08X  = 0x%08X] %s = %s", address, numValue, self.name, value)
			end
		end

		-- Queue up a hook event
		table.insert(memory.hook_queue, {name = self.name, value = value})
	end
end

local POINTER = {}
POINTER.__index = POINTER

function memory.newpointer(addr, offset, pointer, name)
	local pstruct = {}

	name = name or pointer.name

	--log.debug("[MEMORY] POINTER CREATED %08X + %X %q", addr, offset, name or "nil")

	-- Loop through the pointers children
	for poffset, struct in pairs(pointer.struct) do
		local sname = name
		if sname and struct.name then
			sname = sname .. "." .. struct.name
		end
		if struct.type == "pointer" then
			pstruct[poffset] = memory.newpointer(NULL, poffset, struct, sname)
		else
			pstruct[poffset] = memory.newvalue(NULL, poffset, struct, sname)
		end
	end

	return setmetatable({
		parent = addr ~= NULL and pointer or nil,
		name = name,
		address = addr,
		offset = offset,
		location = NULL,
		struct = pstruct,
		debug = pointer.debug,
	}, POINTER)
end

function POINTER:getAddress()
	return ("0x%08X"):format(self.address + self.offset)
end

function POINTER:getPointerPath()
	local parent = self
	while parent do
		local path = parent:getAddress()
		path = parent:getAddress() .. " -> " .. path
		parent = parent.parent
	end
	return path
end

do
	local cast = ffi.cast
	local GC_RAM_START = cast("uint32_t", 0x80000000)
	local GC_RAM_END = cast("uint32_t", 0x81800000)
	local WII_RAM_START = cast("uint32_t", 0x90000000)
	local WII_RAM_END = cast("uint32_t", 0x94000000)

	local function isValidPointer(ptr)
		ptr = cast("uint32_t", ptr)
		return ptr ~= NULL and ((ptr >= GC_RAM_START and ptr <= GC_RAM_END) or (ptr >= WII_RAM_START and ptr <= WII_RAM_END))
	end

	function POINTER:update()
		local addr = self.address + self.offset
		local ploc = memory.readUInt(addr)
		local valid = isValidPointer(ploc)

		if self.location ~= ploc then
			self.location = ploc

			if self.debug then
				if valid then
					log.debug("[MEMORY] [0x%08X -> 0x%08X] %s -> 0x%08X", addr, ploc, self.name, ploc)
				else
					log.debug("[MEMORY] [0x%08X -> 0x0 (NULL)] %s -> 0x%08X", addr, self.name, ploc)
				end
			end
		end

		if valid then
			for offset, struct in pairs(self.struct) do
				-- Set the address space to be where the containing pointer is pointing to
				struct.address = ploc
				-- Update the value/pointer recursively
				struct:update()
			end
		end
	end
end

function memory.loadmap(map)
	for address, struct in pairs(map) do
		if struct.type == "pointer" then
			memory.map[address] = memory.newpointer(address, NULL, struct)
		else
			memory.map[address] = memory.newvalue(address, NULL, struct)
		end
	end
end

function memory.hasPermissions()
	return memory.permissions
end

function memory.isInGame()
	local gid = memory.gameid
	local vcid = memory.vcid
	return gid ~= GAME_NONE or vcid ~= VC_NONE
end

function memory.isMelee()
	local gid = memory.gameid
	local version = memory.version

	if not gid or not version then return false end

	-- Force the GAMEID and VERSION to be Melee 1.02, since Fizzi seems to be using the gameid address space for something..
	-- (Slippi override removed)
	-- if not memory.isSupportedGame(gid, version) and gid ~= GAME_NONE and PANEL_SETTINGS:IsSlippiNetplay() then
	-- 	gid = "GALE01"
	-- 	version = 0x02
	-- end

	-- See if this GameID is a clone of another
	local clone = memory.clones[gid] and memory.clones[gid][version] or nil

	if clone then
		version = clone.version
		gid = clone.id
	end

	return gid == "GALE01" and version == 0x02
end

local timer = love.timer.getTime()

function memory.isSupportedGame(gid, version)
	-- Skip NVIDIA shader entirely
	if gid == "nvph" then
		return false
	end
	return love.filesystem.getInfo(string.format("modules/games/%s-%d.lua", gid, version)) ~= nil
end

function memory.loadGameScript(path)
	-- Skip NVIDIA shader detection entirely
	if path == "nvph" then
		log.info("[KARPHIN] Skipping NVIDIA shader detection: %s", path)
		return false
	end
	
	-- Try to load the game table
	local status, result = xpcall(require, debug.traceback, ("games.%s"):format(path))

	if status and type(result) == "table" then
		memory.game = result
		log.info("[KARPHIN] Loaded game config: %s", path)
		notification.info(("Game %q detected"):format(path))
		if not result.translateCStick then
			result.translateCStick = result.translateJoyStick
		end
		memory.init(result.memorymap)
		return true
	else
		-- Don't show error for NVIDIA shader
		if path ~= "nvph" then
			notification.error(("Unsupported game %s"):format(path))
			notification.error("Playing slippi netplay? Press 'escape' and enable Rollback/Netplay mode")
		end
		log.error("[KARPHIN] %s", result) -- result variable is an error string
		return false
	end
end

-- Track last seen game ID/version for debug logging
local lastLoggedGid = nil
local lastLoggedVersion = nil

-- Debounce state for game detection
local lastDetectGid = GAME_NONE
local lastDetectVersion = 0
local lastDetectVcid = VC_NONE
local stableDetectCount = 0
local noneDetectCount = 0
local STABLE_THRESHOLD = 2
local NONE_THRESHOLD = 2

-- Cooldown after RAM offset changes to ignore transient reads
local detectCooldownUntil = 0

-- Watchdog for stale RAM offset when process isn't hooked
local offsetStuckSince = 0
local OFFSET_STALE_SECS = 0.6

-- Watchdog for bad handles when reads return NONE continuously
local noneWhileHookedCount = 0
local NONE_HANDLE_STALE_FRAMES = 120 -- Increased from 60 to be much less aggressive

-- Track when process was last seen to avoid flashing during rehooking
local lastProcessSeenTime = love.timer.getTime()
local PROCESS_GONE_THRESHOLD = 2.0 -- Show "Waiting" only after 2 seconds of no process

-- Cooldown after forced rehook to prevent immediate re-triggering
local lastForcedRehookTime = 0
local FORCED_REHOOK_COOLDOWN = 8.0 -- Increased from 3.0 to prevent rehooking loops

-- Suppress "Waiting for KARphin" during forced rehook phases
local suppressWaitingTitleUntil = 0
local REHOOK_SUPPRESSION_TIME = 2.0 -- Suppress waiting title for 2 seconds after forced rehook

function memory.findGame()
	local gid = memory.readGameID()
	local version = memory.readGameVersion()
	local vcid = memory.readVirtualConsoleID()

	-- If gid is NONE, ignore transient version reads
	if gid == GAME_NONE then
		version = 0
	end

	-- Debounce current detection tuple (run BEFORE any early returns)
	local isNone = (gid == GAME_NONE and vcid == VC_NONE)
	local sameAsLast = (gid == lastDetectGid and version == lastDetectVersion and vcid == lastDetectVcid)
	if isNone then
		noneDetectCount = noneDetectCount + 1
		stableDetectCount = 0
	else
		if sameAsLast then
			stableDetectCount = stableDetectCount + 1
		else
			stableDetectCount = 1
		end
	end
	lastDetectGid = gid
	lastDetectVersion = version
	lastDetectVcid = vcid

	-- 🔒 FIX: Skip "nvph" game ID entirely (NVIDIA shader, not a game)
	if gid == "nvph" then
		log.info("[KARPHIN] Skipping NVIDIA shader detection: %s", gid)
		return  -- Exit early, do not process "nvph" as a game
	end

	-- Debug: Log what we're reading when stuck (much less frequent to reduce spam)
	if noneWhileHookedCount > 60 and noneWhileHookedCount % 60 == 0 then
		log.debug("[KARPHIN] Stuck reading NONE - gid: %s, vcid: %s, count: %d", 
			gid == GAME_NONE and "NONE" or gid, 
			vcid == VC_NONE and "NONE" or vcid, 
			noneWhileHookedCount)
	end

	-- NONE-while-hooked watchdog: if we’re hooked + have offset but keep seeing NONE, force rehook
	if process:hasProcess() and process:hasGamecubeRAMOffset() then
		local now = love.timer.getTime()
		-- Only allow forced rehook if we're not in cooldown period
		if (now - lastForcedRehookTime) > FORCED_REHOOK_COOLDOWN then
			if gid == GAME_NONE and vcid == VC_NONE then
				noneWhileHookedCount = noneWhileHookedCount + 1
				if noneWhileHookedCount > NONE_HANDLE_STALE_FRAMES then
					-- Additional check: verify process is actually still running before forcing rehook
					if process:isProcessActive() then
						-- Process is still active, but we've been reading NONE for a very long time
						-- Check if we have a clearly wrong RAM offset (512MB when no game is loaded)
						local currentSize = process:getGamecubeRAMSize()
						if currentSize > 512 * 1024 * 1024 then -- 512MB threshold (increased from 64MB for netplay compatibility)
							log.debug("[KARPHIN] Process active but stuck reading NONE with large RAM offset (%s); clearing offset", string.toSize(currentSize))
							process:clearGamecubeRAMOffset()
							noneWhileHookedCount = 0
							lastForcedRehookTime = now
							suppressWaitingTitleUntil = now + REHOOK_SUPPRESSION_TIME
							log.debug("[KARPHIN] Set suppression until %.1fs from now", REHOOK_SUPPRESSION_TIME)
							return
						else
							-- RAM offset seems reasonable, force full rehook
							log.debug("[KARPHIN] Process active but stuck reading NONE; forcing rehook to refresh RAM offset")
							process:close()
							process:clearGamecubeRAMOffset()
							memory.hooked = false
							noneWhileHookedCount = 0
							lastForcedRehookTime = now
							suppressWaitingTitleUntil = now + REHOOK_SUPPRESSION_TIME
							log.debug("[KARPHIN] Set suppression until %.1fs from now", REHOOK_SUPPRESSION_TIME)
							return
						end
					else
						-- Process is truly stale, force rehook
						log.debug("[KARPHIN] Process handle stale; forcing rehook")
						process:close()
						process:clearGamecubeRAMOffset()
						memory.hooked = false
						noneWhileHookedCount = 0
						lastForcedRehookTime = now
						suppressWaitingTitleUntil = now + REHOOK_SUPPRESSION_TIME
						log.debug("[KARPHIN] Set suppression until %.1fs from now", REHOOK_SUPPRESSION_TIME)
						return
					end
				end
			else
				noneWhileHookedCount = 0
			end
		end
	end

	-- Only log if the game ID or version has changed and gid is not NONE
	if gid ~= GAME_NONE and (lastLoggedGid ~= gid or lastLoggedVersion ~= version) then
		log.debug("[KARPHIN] Processing game ID: %s, version: %d", gid, version)
		lastLoggedGid = gid
		lastLoggedVersion = version
	end

	-- Force the GAMEID and VERSION to be Melee 1.02, since Fizzi seems to be using the gameid address space for something..
	-- (Slippi override removed)
	-- if not memory.isSupportedGame(gid, version) and gid ~= GAME_NONE and PANEL_SETTINGS:IsSlippiNetplay() then
	-- 	gid = "GKYE01"
	-- 	version = 0
	-- end

	-- When playing Slippi netplay.. the game ID can and will change..
	-- This would normally break things, but if you enable Rollback/Netplay mode it will force the gameid to always be GALE01 v1.02
	local meleeMode = (memory.isMelee() and memory.gameid ~= gid)

	-- Ignore detection during cooldown to avoid transient IDs
	local now = love.timer.getTime()
	if now < detectCooldownUntil then
		return
	end

	-- Fast-path: if gid is a supported game ID, bypass debounce and open immediately
	if gid ~= GAME_NONE and memory.isSupportedGame(gid, version) and not memory.ingame then
		memory.reset()
		memory.ingame = true
		memory.gameid = gid
		memory.version = version
		log.info("[KARPHIN] Game: %s revision %i", gid, version)
		love.updateTitle(("K'Overlay - KARphin hooked (%s-%i)"):format(gid, version))
		local clone = memory.clones[gid] and memory.clones[gid][version] or nil
		if clone then
			version = clone.version
			gid = clone.id
		end
		if memory.loadGameScript(("%s-%d"):format(gid, version)) then
			memory.runhook("OnGameOpen", gid, version)
		end
		return
	end

	-- Enforce debounce: require stability before opening/closing
	if not memory.ingame then
		-- If we have a non-NONE gid but it's not stable yet, defer
		if gid ~= GAME_NONE and stableDetectCount < STABLE_THRESHOLD then
			return
		end
		-- If VC-only detection but not stable yet, defer
		if gid == GAME_NONE and vcid ~= VC_NONE and stableDetectCount < STABLE_THRESHOLD then
			return
		end
	else
		-- Suppress close until we see consecutive NONE reads
		if (gid == GAME_NONE and vcid == VC_NONE) and noneDetectCount < NONE_THRESHOLD then
			return
		end
	end

	if not memory.ingame and gid == GAME_NONE and vcid ~= VC_NONE then
		memory.reset()
		memory.ingame = true
		memory.vcid = vcid

		log.info("[KARPHIN] Game: %s", vcid)
		love.updateTitle(("K'Overlay - KARphin hooked (%s)"):format(vcid))

		-- Check for VC clones
		vcid = memory.vcclones[vcid] or vcid

		if memory.loadGameScript(vcid) then
			memory.runhook("OnGameOpen", vcid)
		end
	elseif (not memory.ingame or meleeMode) and gid ~= GAME_NONE then
		-- Skip NVIDIA shader detection here as well
		if gid == "nvph" then
			log.info("[KARPHIN] Skipping NVIDIA shader in game detection: %s", gid)
			return
		end
		
		memory.reset()
		memory.ingame = true
		memory.gameid = gid
		memory.version = version

		log.info("[KARPHIN] Game: %s revision %i", gid, version)
		love.updateTitle(("K'Overlay - KARphin hooked (%s-%i)"):format(gid, version))

		-- See if this GameID is a clone of another
		local clone = memory.clones[gid] and memory.clones[gid][version] or nil

		if clone then
			version = clone.version
			gid = clone.id
		end

		if memory.loadGameScript(("%s-%d"):format(gid, version)) then
			memory.runhook("OnGameOpen", gid, version)
		end
	elseif (memory.ingame or meleeMode) and (gid == GAME_NONE and vcid == VC_NONE) then
		if noneDetectCount < NONE_THRESHOLD then return end
		memory.ingame = false
		memory.gameid = gid
		memory.vcid = vcid
		memory.version = version

		love.updateTitle("K'Overlay - KARphin hooked")
		memory.runhook("OnGameClosed")
		memory.process:clearGamecubeRAMOffset() -- Clear the memory address space location (When a new game is opened, we recheck this)
		log.info("[KARPHIN] Game closed..")
	end

	-- Debounce current detection tuple
	local isNone = (gid == GAME_NONE and vcid == VC_NONE)
	local sameAsLast = (gid == lastDetectGid and version == lastDetectVersion and vcid == lastDetectVcid)
	if isNone then
		noneDetectCount = noneDetectCount + 1
		stableDetectCount = 0
		lastDetectGid = gid
		lastDetectVersion = version
		lastDetectVcid = vcid
	else
		if sameAsLast then
			stableDetectCount = stableDetectCount + 1
		else
			stableDetectCount = 1
			lastDetectGid = gid
			lastDetectVersion = version
			lastDetectVcid = vcid
		end
		noneDetectCount = 0
	end
end

function memory.update()
	if not memory.hasPermissions() then return end

	if not process:isProcessActive() and process:hasProcess() then
		-- Process handle is stale, close it but don't update title yet
		process:close()
		log.info("[KARPHIN] Unhooked")
		memory.hooked = false
	end

	local t = love.timer.getTime()

	-- Only check for the dolphin process once per second to reduce CPU load
	if not process:hasProcess() or not process:hasGamecubeRAMOffset() then
		-- Check if we should show "Waiting for KARphin" after process has been gone for a while
		-- But suppress during forced rehook phases to prevent flashing
		if not process:hasProcess() and (t - lastProcessSeenTime) > PROCESS_GONE_THRESHOLD and t >= suppressWaitingTitleUntil then
			-- Only set title once, not every frame
			if not memory.waitingTitleSet then
				log.debug("[KARPHIN] Setting title to 'Waiting for KARphin' - process gone for %.1fs", (t - lastProcessSeenTime))
				love.updateTitle("K'Overlay - Waiting for KARphin..")
				memory.waitingTitleSet = true
			end
		elseif not process:hasProcess() and (t - lastProcessSeenTime) > PROCESS_GONE_THRESHOLD and t < suppressWaitingTitleUntil then
			-- Only log suppression once per second to reduce spam
			if not memory.lastSuppressionLog or (t - memory.lastSuppressionLog) > 1.0 then
				log.debug("[KARPHIN] Suppressed 'Waiting for KARphin' - suppression active for %.1fs", (suppressWaitingTitleUntil - t))
				memory.lastSuppressionLog = t
			end
		elseif process:hasProcess() then
			-- Reset flag when we have a process again
			memory.waitingTitleSet = false
		end
		if not process:hasGamecubeRAMOffset() then
			-- No offset yet: normal rate-limited discovery
			offsetStuckSince = 0
			if timer <= t then
				timer = t + 0.5
				if process:findprocess() then
					log.info("[KARPHIN] Hooked")
					love.updateTitle("K'Overlay - KARphin hooked")
					memory.hooked = true
					lastProcessSeenTime = t
				elseif not process:hasGamecubeRAMOffset() and process:findGamecubeRAMOffset() then
					local offset = process:getGamecubeRAMOffset()
					local size = process:getGamecubeRAMSize()
					log.debug("[KARPHIN] Watching ram address: 0x%X [%s]", offset, string.toSize(size))
					
					-- Validate the RAM offset - if it's 512MB, it's likely wrong when no game is loaded
					if size > 512 * 1024 * 1024 then -- 512MB threshold (increased from 64MB for netplay compatibility)
						log.debug("[KARPHIN] Large RAM offset detected (%s) - likely wrong, clearing", string.toSize(size))
						process:clearGamecubeRAMOffset()
						-- Don't start detection cooldown since we cleared the offset
						return
					end
					
					-- Start cooldown to let memory settle
					detectCooldownUntil = t + 0.75
					stableDetectCount = 0
					noneDetectCount = 0
					lastDetectGid = GAME_NONE
					lastDetectVersion = 0
					lastDetectVcid = VC_NONE
				end
			end
		else
			-- We have an offset but no process handle: aggressively hook, and if stuck too long, reset offset
			if process:findprocess() then
				log.info("[KARPHIN] Hooked")
				love.updateTitle("K'Overlay - KARphin hooked")
				memory.hooked = true
				lastProcessSeenTime = t
				offsetStuckSince = 0
			else
				if offsetStuckSince == 0 then
					offsetStuckSince = t
				elseif (t - offsetStuckSince) > OFFSET_STALE_SECS then
					-- Offset is stale; clear and rescan to avoid hanging at Watching ram address
					process:clearGamecubeRAMOffset()
					log.debug("[KARPHIN] RAM offset stale; clearing and rescanning")
					offsetStuckSince = 0
					-- Try immediately to find process and offset again
					if process:findprocess() then
						log.info("[KARPHIN] Hooked")
						love.updateTitle("K'Overlay - KARphin hooked")
						memory.hooked = true
						lastProcessSeenTime = t
					elseif process:findGamecubeRAMOffset() then
						local offset = process:getGamecubeRAMOffset()
						local size = process:getGamecubeRAMSize()
						log.debug("[KARPHIN] Watching ram address: 0x%X [%s]", offset, string.toSize(size))
						
						-- Validate the RAM offset - if it's 512MB, it's likely wrong when no game is loaded
						if size > 512 * 1024 * 1024 then -- 512MB threshold (increased from 64MB for netplay compatibility)
							log.debug("[KARPHIN] Large RAM offset detected (%s) - likely wrong, clearing", string.toSize(size))
							process:clearGamecubeRAMOffset()
							-- Don't start detection cooldown since we cleared the offset
							return
						end
						
						detectCooldownUntil = t + 0.75
						stableDetectCount = 0
						noneDetectCount = 0
						lastDetectGid = GAME_NONE
						lastDetectVersion = 0
						lastDetectVcid = VC_NONE
					end
				end
			end
		end
	else
		offsetStuckSince = 0
		memory.updatememory()

		local frame = memory.frame or 0
		if frame == 0 or memory.game_frame ~= frame then
			memory.game_frame = frame
			memory.runhooks()
		end
	end
end

function memory.init(map)
	memory.initialized = true
	memory.loadmap(map)
	log.info("[MEMORY] Mapped game memory structure")
end

function memory.reset()
	memory.initialized = false
	memory.ingame = false
	memory.map = {}
	memory.values = {}
	memory.gameid = GAME_NONE
	memory.version = 0
	memory.game = nil
	setmetatable(memory, {__index = memory.values})
end

function memory.updatememory()
	-- Avoid reads if the emulator process has exited mid-frame
	if not process:hasProcess() then return end
	memory.findGame()

	if memory.ingame then
		for addr, value in pairs(memory.map) do
			value:update()
		end
	end
end

local function hookPattern(name)
	-- Convert '*' into capture patterns
	if string.find(name, "*", 1, true) then
		return true, '^' .. name:escape():gsub("%%%*", "([^.]-)") .. '$'
	end
	return false, name
end

function memory.hook(name, desc, callback)
	local wildcard, name = hookPattern(name)
	if wildcard then
		memory.wildcard_hooks[name] = memory.wildcard_hooks[name] or {}
		memory.wildcard_hooks[name][desc] = callback
	else
		memory.hooks[name] = memory.hooks[name] or {}
		memory.hooks[name][desc] = callback
	end
end

function memory.unhook(name, desc)
	memory.hook(name, desc, nil)
end

function memory.runhooks()
	local pop
	while true do
		pop = table.remove(memory.hook_queue, 1)
		if not pop then break end
		memory.runhook(pop.name, pop.value)
	end
end

do
	local args = {}
	local matches = {}

	function memory.runhook(name, ...)
		-- Normal hooks
		if memory.hooks[name] then
			for desc, callback in pairs(memory.hooks[name]) do
				local succ, err
				if type(desc) == "table" then
					-- Assume a table is an object, so call it as so
					succ, err = xpcall(callback, debug.traceback, desc, ...)
				else
					succ, err = xpcall(callback, debug.traceback, ...)
				end
				if not succ then
					log.error("[MEMORY] hook error: %s (%s)", desc, err)
				end
			end
		end

		local varargs = {...}

		-- Allow for wildcard hooks
		for pattern, hooks in pairs(memory.wildcard_hooks) do
			if string.find(name, pattern) then
				args = {}
				matches = {name:match(pattern)}

				for k, match in ipairs(matches) do
					table.insert(args, tonumber(match) or match)
				end
				for k, arg in ipairs(varargs) do
					table.insert(args, arg)
				end

				for desc, callback in pairs(hooks) do
					local succ, err
					if type(desc) == "table" then
						-- Assume a table is an object, so call it as so
						succ, err = xpcall(callback, debug.traceback, desc, unpack(args))
					else
						succ, err = xpcall(callback, debug.traceback, unpack(args))
					end
					if not succ then
						log.error("[MEMORY] wildcard hook error: %s (%s)", desc, err)
					end
				end
			end
		end
	end
end

function memory.isHookedForUI()
	local t = love.timer.getTime()
	-- If we're in a suppression period, pretend we're hooked to prevent UI flashing
	if t < suppressWaitingTitleUntil then
		return true
	end
	return memory.hooked
end

return memory