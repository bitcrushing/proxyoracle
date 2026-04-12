-- ProxyOracle Updater for OpenComputers
--
-- Usage:
--   update              Update default /usr/lib and /usr/bin
--   update /mnt/abc     Update files on external drive

local filesystem = require("filesystem")
local internet = require("internet")
local shell = require("shell")
local component = require("component")

local args = {...}

local BASE_URL = "https://raw.githubusercontent.com/bitcrushing/ProxyOracle/main/client/"

local ALL_FILES = {
  "json.lua", "config.lua", "claude_api.lua", "ui.lua", "tools.lua",
  "claude.lua", "update.lua"
}
local BIN_NAMES = {["claude.lua"] = "claude", ["update.lua"] = "update"}

local function fetch(url)
  if not url:match("^https?://") then
    url = BASE_URL .. url
  end
  local content = {}
  local ok, err = pcall(function()
    local handle = internet.request(url)
    if handle then
      for chunk in handle do
        table.insert(content, chunk)
      end
    end
  end)
  if not ok then return nil, err end
  local result = table.concat(content)
  if #result == 0 then return nil, "Empty response" end
  return result
end

local function writeFile(path, content)
  local dir = filesystem.path(path)
  if dir and dir ~= "" and not filesystem.exists(dir) then
    filesystem.makeDirectory(dir)
  end
  local file, err = io.open(path, "w")
  if not file then return false, err end
  file:write(content)
  file:close()
  return true
end

local function update()
  local targetBase = args[1]
  local externalInstall = false
  local INSTALL_DIR

  if targetBase then
    if not filesystem.exists(targetBase) then
      print("Error: Path not found: " .. targetBase)
      return false
    end
    INSTALL_DIR = filesystem.concat(targetBase, "claude")
    externalInstall = true
  end

  print("=== ProxyOracle Updater ===")
  print("")
  print("Source: " .. BASE_URL)
  if externalInstall then
    print("Target: " .. INSTALL_DIR)
  end
  print("")

  if not component.isAvailable("internet") then
    print("Error: Internet Card required!")
    return false
  end

  local updated = 0
  local failed = 0

  if externalInstall then
    if not filesystem.exists(INSTALL_DIR) then
      filesystem.makeDirectory(INSTALL_DIR)
    end

    print("Downloading files...")
    for _, fileName in ipairs(ALL_FILES) do
      io.write("  " .. fileName .. "... ")
      local content, err = fetch(fileName)
      if content then
        local dst = filesystem.concat(INSTALL_DIR, fileName)
        if filesystem.exists(dst) then filesystem.remove(dst) end
        local ok, writeErr = writeFile(dst, content)
        if ok then
          print("OK (" .. #content .. " bytes)")
          updated = updated + 1
        else
          print("WRITE FAILED: " .. tostring(writeErr))
          failed = failed + 1
        end
      else
        print("FETCH FAILED: " .. tostring(err))
        failed = failed + 1
      end
    end

    print("Updating launchers...")
    if not filesystem.exists("/usr/bin") then
      filesystem.makeDirectory("/usr/bin")
    end
    for fileName, binName in pairs(BIN_NAMES) do
      local target = filesystem.concat(INSTALL_DIR, fileName)
      local launcherPath = "/usr/bin/" .. binName
      local launcher = '-- Launcher (external drive)\nlocal fn=loadfile("' .. target .. '")\nif fn then fn(...) end\n'
      local file = io.open(launcherPath, "w")
      if file then
        file:write(launcher)
        file:close()
        print("  + " .. binName .. " -> " .. target)
      end
    end

  else
    print("Downloading files...")
    for _, fileName in ipairs(ALL_FILES) do
      local binName = BIN_NAMES[fileName]
      local dst = binName and ("/usr/bin/" .. binName) or ("/usr/lib/" .. fileName)
      io.write("  " .. (binName or fileName) .. "... ")
      local content, err = fetch(fileName)
      if content then
        if filesystem.exists(dst) then filesystem.remove(dst) end
        local ok, writeErr = writeFile(dst, content)
        if ok then
          print("OK (" .. #content .. " bytes)")
          updated = updated + 1
        else
          print("WRITE FAILED: " .. tostring(writeErr))
          failed = failed + 1
        end
      else
        print("FETCH FAILED: " .. tostring(err))
        failed = failed + 1
      end
    end
  end

  print("")
  print("Update complete: " .. updated .. " updated, " .. failed .. " failed")
  return failed == 0
end

update()
