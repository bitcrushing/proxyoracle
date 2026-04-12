-- ProxyOracle Installer for OpenComputers
--
-- Usage:
--   install              Install to default /usr/lib and /usr/bin
--   install /mnt/abc     Install to a secondary drive (all files in one dir)

local filesystem = require("filesystem")
local shell = require("shell")
local component = require("component")

local args = {...}

local ALL_FILES = {"json.lua", "config.lua", "claude_api.lua", "ui.lua", "tools.lua", "claude.lua", "update.lua"}
local BIN_NAMES = {["claude.lua"] = "claude", ["update.lua"] = "update"}

print("=== ProxyOracle Installer ===")
print("")

local targetBase = args[1]
local externalInstall = false
local INSTALL_DIR

if targetBase then
  if not filesystem.exists(targetBase) then
    print("Error: Path not found: " .. targetBase)
    print("")
    print("Available mounted drives:")
    for addr in component.list("filesystem") do
      for proxy, path in filesystem.mounts() do
        if proxy.address == addr then
          print("  " .. path .. "  (" .. addr:sub(1, 8) .. ")")
        end
      end
    end
    return
  end
  INSTALL_DIR = filesystem.concat(targetBase, "claude")
  externalInstall = true
  print("Installing to external drive: " .. INSTALL_DIR)
else
  print("Installing to boot drive")
end

local sourceDir = shell.resolve(".")
print("Source: " .. sourceDir)
print("")

if externalInstall then
  if not filesystem.exists(INSTALL_DIR) then
    print("Creating " .. INSTALL_DIR .. "...")
    filesystem.makeDirectory(INSTALL_DIR)
  end

  print("Installing files...")
  for _, file in ipairs(ALL_FILES) do
    local src = filesystem.concat(sourceDir, file)
    local dst = filesystem.concat(INSTALL_DIR, file)
    if filesystem.exists(src) then
      if filesystem.exists(dst) then filesystem.remove(dst) end
      local success = filesystem.copy(src, dst)
      print(success and ("  + " .. file) or ("  ! Failed: " .. file))
    else
      print("  ? Missing: " .. file)
    end
  end

  print("")
  print("Creating launchers on boot drive...")
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
  if not filesystem.exists("/usr/lib") then filesystem.makeDirectory("/usr/lib") end
  if not filesystem.exists("/usr/bin") then filesystem.makeDirectory("/usr/bin") end

  print("Installing files...")
  for _, fileName in ipairs(ALL_FILES) do
    local src = filesystem.concat(sourceDir, fileName)
    local binName = BIN_NAMES[fileName]
    local dst = binName and ("/usr/bin/" .. binName) or ("/usr/lib/" .. fileName)
    if filesystem.exists(src) then
      if filesystem.exists(dst) then filesystem.remove(dst) end
      local success = filesystem.copy(src, dst)
      print(success and ("  + " .. (binName or fileName)) or ("  ! Failed: " .. fileName))
    else
      print("  ? Missing: " .. fileName)
    end
  end
end

print("")
print("Installation complete!")
print("")
print("Next steps:")
print("  1. Start the ProxyOracle proxy server on your host machine")
print("  2. Run 'claude --setup' to configure proxy connection")
print("  3. Run 'claude' to start chatting!")
print("")
print("No TLS library or Data Card required.")
print("Requires: Internet Card")
