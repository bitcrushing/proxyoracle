-- Tool definitions and execution for Claude Code
-- Implements filesystem and shell tools for OpenComputers
-- No dependency on ui.lua or claude_api.lua

local filesystem = require("filesystem")
local shell = require("shell")

local tools = {}

-- Maximum output sizes — conservative for 1MB OC systems
-- Tool results stay in conversation history and get re-sent each turn
local MAX_READ_LINES = 200
local MAX_READ_BYTES = 8192    -- 8KB
local MAX_RUN_OUTPUT = 4096    -- 4KB
local MAX_GLOB_RESULTS = 50
local MAX_GREP_RESULTS = 25
local MAX_WALK_DEPTH = 10

-- Tool definitions for the API request (tools array)
tools.TOOL_DEFINITIONS = {
  {
    name = "Read",
    description = "Read a file. Use absolute paths.",
    input_schema = {
      type = "object",
      properties = {
        file_path = {type = "string"},
        offset = {type = "number"},
        limit = {type = "number"}
      },
      required = {"file_path"}
    }
  },
  {
    name = "Write",
    description = "Write a file. Requires confirmation.",
    input_schema = {
      type = "object",
      properties = {
        file_path = {type = "string"},
        content = {type = "string"}
      },
      required = {"file_path", "content"}
    }
  },
  {
    name = "Edit",
    description = "Find and replace text in a file. Requires confirmation.",
    input_schema = {
      type = "object",
      properties = {
        file_path = {type = "string"},
        old_string = {type = "string"},
        new_string = {type = "string"},
        replace_all = {type = "boolean"}
      },
      required = {"file_path", "old_string", "new_string"}
    }
  },
  {
    name = "Run",
    description = "Run a shell command. Requires confirmation.",
    input_schema = {
      type = "object",
      properties = {
        command = {type = "string"}
      },
      required = {"command"}
    }
  },
  {
    name = "Glob",
    description = "Find files by glob pattern (*, **, ?).",
    input_schema = {
      type = "object",
      properties = {
        pattern = {type = "string"},
        path = {type = "string"}
      },
      required = {"pattern"}
    }
  },
  {
    name = "Grep",
    description = "Search file contents by Lua pattern.",
    input_schema = {
      type = "object",
      properties = {
        pattern = {type = "string"},
        path = {type = "string"},
        include = {type = "string"}
      },
      required = {"pattern"}
    }
  },
  {
    name = "Fetch",
    description = "HTTP GET a URL. Returns text content, HTML tags stripped.",
    input_schema = {
      type = "object",
      properties = {
        url = {type = "string"}
      },
      required = {"url"}
    }
  },
  {
    name = "Component",
    description = "Access OC hardware. action='list' shows components. action='call' invokes a method (address, method, args[]).",
    input_schema = {
      type = "object",
      properties = {
        action = {type = "string"},
        address = {type = "string"},
        method = {type = "string"},
        args = {type = "array", items = {}}
      },
      required = {"action"}
    }
  },
  {
    name = "Inventory",
    description = "Read inventories via transposer/adapter. side=0-5. Optional slot number.",
    input_schema = {
      type = "object",
      properties = {
        side = {type = "number"},
        slot = {type = "number"}
      },
      required = {"side"}
    }
  },
  {
    name = "Redstone",
    description = "Read/set redstone. action='get' reads input, action='set' sets output (value 0-15).",
    input_schema = {
      type = "object",
      properties = {
        action = {type = "string"},
        side = {type = "number"},
        value = {type = "number"}
      },
      required = {"action", "side"}
    }
  },
  {
    name = "ME",
    description = "AE2/ME system. action='items' (optional filter), action='craft' (item, count), action='status'.",
    input_schema = {
      type = "object",
      properties = {
        action = {type = "string"},
        filter = {type = "string"},
        item = {type = "string"},
        count = {type = "number"}
      },
      required = {"action"}
    }
  },
  {
    name = "Robot",
    description = "Control robot. action: move/turn/swing/place/use/detect/inspect/suck/drop/inventory. direction: forward/up/down. side: left/right.",
    input_schema = {
      type = "object",
      properties = {
        action = {type = "string"},
        direction = {type = "string"},
        side = {type = "string"},
        slot = {type = "number"}
      },
      required = {"action"}
    }
  },
  {
    name = "Scan",
    description = "Terrain scanning. action='block' (x,y,z offset), action='area' (w,d,h volume), action='position' (GPS coords).",
    input_schema = {
      type = "object",
      properties = {
        action = {type = "string"},
        x = {type = "number"},
        y = {type = "number"},
        z = {type = "number"},
        w = {type = "number"},
        d = {type = "number"},
        h = {type = "number"}
      },
      required = {"action"}
    }
  }
}

-- Tools that require user confirmation (conditional on action for some)
local CONFIRM_TOOLS = {Write = true, Edit = true, Run = true, Component = true}

function tools.needsConfirmation(name, input)
  if CONFIRM_TOOLS[name] == true then
    -- Component: only 'call' needs confirmation, 'list' is safe
    if name == "Component" then
      return input and input.action == "call"
    end
    return true
  end
  -- Conditional confirmation by action
  if name == "Redstone" then
    return input and input.action == "set"
  elseif name == "ME" then
    return input and input.action == "craft"
  elseif name == "Robot" then
    local a = input and input.action
    return a == "move" or a == "swing" or a == "place" or a == "drop" or a == "use"
  end
  return false
end

-------------------------------------------------------------------
-- Helper: convert a simple glob pattern to a Lua pattern
-------------------------------------------------------------------
local function escapePatternChar(c)
  if c:match("[%(%)%.%%%+%-%[%]%^%$]") then
    return "%" .. c
  end
  return c
end

local function globToLuaPattern(glob)
  local result = {}
  local i = 1
  local len = #glob
  while i <= len do
    local c = glob:sub(i, i)
    if c == "*" then
      if glob:sub(i + 1, i + 1) == "*" then
        -- ** matches anything including path separators
        if glob:sub(i + 2, i + 2) == "/" then
          table.insert(result, ".*")
          i = i + 3
        else
          table.insert(result, ".*")
          i = i + 2
        end
      else
        -- * matches anything except /
        table.insert(result, "[^/]*")
        i = i + 1
      end
    elseif c == "?" then
      table.insert(result, "[^/]")
      i = i + 1
    else
      table.insert(result, escapePatternChar(c))
      i = i + 1
    end
  end
  return "^" .. table.concat(result) .. "$"
end

local function globMatch(pattern, path)
  local luaPat = globToLuaPattern(pattern)
  return path:match(luaPat) ~= nil
end

-------------------------------------------------------------------
-- Helper: recursively walk a directory
-------------------------------------------------------------------
local function walkDirectory(basePath, callback, maxDepth)
  maxDepth = maxDepth or MAX_WALK_DEPTH
  if maxDepth <= 0 then return end

  local ok, iter = pcall(filesystem.list, basePath)
  if not ok or not iter then return end

  for entry in iter do
    local fullPath = filesystem.concat(basePath, entry)
    -- entry ends with / if directory in OC
    local isDir = entry:sub(-1) == "/" or filesystem.isDirectory(fullPath)
    local cleanEntry = entry:gsub("/$", "")
    local cleanPath = filesystem.concat(basePath, cleanEntry)

    if isDir then
      -- Skip hidden directories
      if cleanEntry:sub(1, 1) ~= "." then
        callback(cleanPath, true)
        walkDirectory(cleanPath, callback, maxDepth - 1)
      end
    else
      callback(cleanPath, false)
    end
  end
end

-------------------------------------------------------------------
-- Tool: Read
-------------------------------------------------------------------
local function executeRead(input)
  local path = input.file_path
  if not path then return "Error: file_path is required", true end

  if not filesystem.exists(path) then
    return "Error: File not found: " .. path, true
  end
  if filesystem.isDirectory(path) then
    return "Error: Path is a directory, not a file: " .. path, true
  end

  local file, err = io.open(path, "r")
  if not file then
    return "Error: Cannot open file: " .. tostring(err), true
  end

  local offset = math.max(1, math.floor(input.offset or 1))
  local limit = math.min(MAX_READ_LINES, math.floor(input.limit or MAX_READ_LINES))
  local lines = {}
  local lineNum = 0
  local totalBytes = 0
  local truncated = false

  for line in file:lines() do
    lineNum = lineNum + 1
    if lineNum >= offset and lineNum < offset + limit then
      totalBytes = totalBytes + #line + 1
      if totalBytes > MAX_READ_BYTES then
        truncated = true
        break
      end
      table.insert(lines, string.format("%4d\t%s", lineNum, line))
    end
    if lineNum >= offset + limit then break end
  end

  file:close()

  local result = table.concat(lines, "\n")
  if truncated then
    result = result .. "\n\n(Output truncated at " .. MAX_READ_BYTES .. " bytes)"
  end
  if lineNum == 0 then
    result = "(Empty file)"
  end

  return result, false
end

-------------------------------------------------------------------
-- Tool: Write
-------------------------------------------------------------------
local function executeWrite(input)
  local path = input.file_path
  local content = input.content
  if not path then return "Error: file_path is required", true end
  if not content then return "Error: content is required", true end

  -- Create parent directories
  local dir = filesystem.path(path)
  if dir and dir ~= "" and not filesystem.exists(dir) then
    filesystem.makeDirectory(dir)
  end

  local isNew = not filesystem.exists(path)

  local file, err = io.open(path, "w")
  if not file then
    return "Error: Cannot write to file: " .. tostring(err), true
  end

  file:write(content)
  file:close()

  local action = isNew and "Created" or "Updated"
  return action .. " " .. path .. " (" .. #content .. " bytes)", false
end

-------------------------------------------------------------------
-- Tool: Edit
-------------------------------------------------------------------
local function executeEdit(input)
  local path = input.file_path
  local oldStr = input.old_string
  local newStr = input.new_string
  local replaceAll = input.replace_all

  if not path then return "Error: file_path is required", true end
  if not oldStr then return "Error: old_string is required", true end
  if oldStr == "" then return "Error: old_string cannot be empty", true end
  if not newStr then return "Error: new_string is required", true end

  if not filesystem.exists(path) then
    return "Error: File not found: " .. path, true
  end

  -- Read current content
  local file, err = io.open(path, "r")
  if not file then
    return "Error: Cannot open file: " .. tostring(err), true
  end
  local content = file:read("*a")
  file:close()

  -- Count occurrences using plain find
  local count = 0
  local searchPos = 1
  while true do
    local found = string.find(content, oldStr, searchPos, true)
    if not found then break end
    count = count + 1
    searchPos = found + #oldStr
  end

  if count == 0 then
    return "Error: old_string not found in " .. path, true
  end

  if count > 1 and not replaceAll then
    return "Error: old_string found " .. count .. " times in " .. path .. ". Use replace_all=true or provide a more specific string.", true
  end

  -- Perform replacement
  local result
  if replaceAll then
    -- Replace all occurrences
    local parts = {}
    local pos = 1
    while true do
      local found = string.find(content, oldStr, pos, true)
      if not found then
        table.insert(parts, content:sub(pos))
        break
      end
      table.insert(parts, content:sub(pos, found - 1))
      table.insert(parts, newStr)
      pos = found + #oldStr
    end
    result = table.concat(parts)
  else
    -- Replace first occurrence only
    local found = string.find(content, oldStr, 1, true)
    result = content:sub(1, found - 1) .. newStr .. content:sub(found + #oldStr)
  end

  -- Write back
  file, err = io.open(path, "w")
  if not file then
    return "Error: Cannot write file: " .. tostring(err), true
  end
  file:write(result)
  file:close()

  local replaced = replaceAll and count or 1
  return "Replaced " .. replaced .. " occurrence(s) in " .. path, false
end

-------------------------------------------------------------------
-- Tool: Run
-------------------------------------------------------------------
local function executeRun(input)
  local command = input.command
  if not command then return "Error: command is required", true end

  local outFile = "/tmp/.claude_cmd_out"

  -- If command has its own redirect, run as-is (can't capture output)
  local success
  if command:find(">") then
    success = shell.execute(command)
    return success and "(Command executed, output redirected by command)" or "(Command failed)", not success
  end

  local fullCmd = command .. " > " .. outFile .. " 2>&1"
  success = shell.execute(fullCmd)

  -- Read output
  local output = ""
  if filesystem.exists(outFile) then
    local file = io.open(outFile, "r")
    if file then
      output = file:read("*a") or ""
      file:close()
    end
    -- Clean up temp file
    pcall(filesystem.remove, outFile)
  end

  -- Truncate if too large
  local truncated = false
  if #output > MAX_RUN_OUTPUT then
    output = output:sub(1, MAX_RUN_OUTPUT)
    truncated = true
  end

  local result = output
  if truncated then
    result = result .. "\n\n(Output truncated at " .. MAX_RUN_OUTPUT .. " bytes)"
  end
  if not success then
    result = result .. "\n(Command exited with error)"
  end
  if result == "" then
    result = "(No output)"
  end

  return result, not success
end

-------------------------------------------------------------------
-- Tool: Glob
-------------------------------------------------------------------
local function executeGlob(input)
  local pattern = input.pattern
  if not pattern then return "Error: pattern is required", true end

  local basePath = input.path or shell.getWorkingDirectory() or "/"
  if not filesystem.exists(basePath) then
    return "Error: Path not found: " .. basePath, true
  end
  if not filesystem.isDirectory(basePath) then
    return "Error: Not a directory: " .. basePath, true
  end
  -- Normalize: ensure basePath ends with /
  if basePath:sub(-1) ~= "/" then basePath = basePath .. "/" end

  local matches = {}

  walkDirectory(basePath, function(fullPath, isDir)
    if #matches >= MAX_GLOB_RESULTS then return end

    -- Get path relative to basePath for matching
    local relPath = fullPath
    if basePath ~= "/" then
      if fullPath:sub(1, #basePath) == basePath then
        relPath = fullPath:sub(#basePath + 1)
      end
    end
    if relPath == "" then return end

    if not isDir and globMatch(pattern, relPath) then
      table.insert(matches, fullPath)
    end
  end, MAX_WALK_DEPTH)

  if #matches == 0 then
    return "No files matching: " .. pattern, false
  end

  local result = table.concat(matches, "\n")
  if #matches >= MAX_GLOB_RESULTS then
    result = result .. "\n\n(Results limited to " .. MAX_GLOB_RESULTS .. " entries)"
  end

  return result, false
end

-------------------------------------------------------------------
-- Tool: Grep
-------------------------------------------------------------------
local function executeGrep(input)
  local pattern = input.pattern
  if not pattern then return "Error: pattern is required", true end

  local basePath = input.path or shell.getWorkingDirectory() or "/"
  local includeGlob = input.include

  local results = {}

  local function searchFile(filePath)
    if #results >= MAX_GREP_RESULTS then return end

    local file = io.open(filePath, "r")
    if not file then return end

    local lineNum = 0
    for line in file:lines() do
      lineNum = lineNum + 1
      if #results >= MAX_GREP_RESULTS then break end

      local ok, found = pcall(string.find, line, pattern)
      if ok and found then
        -- Truncate long lines
        local display = #line > 200 and line:sub(1, 200) .. "..." or line
        table.insert(results, filePath .. ":" .. lineNum .. ":" .. display)
      end
    end

    file:close()
  end

  if filesystem.exists(basePath) and not filesystem.isDirectory(basePath) then
    -- Search single file
    searchFile(basePath)
  else
    -- Search directory recursively
    walkDirectory(basePath, function(fullPath, isDir)
      if isDir then return end
      if #results >= MAX_GREP_RESULTS then return end

      -- Apply include filter
      if includeGlob then
        local name = fullPath:match("[^/]+$") or fullPath
        if not globMatch(includeGlob, name) then return end
      end

      searchFile(fullPath)
    end, MAX_WALK_DEPTH)
  end

  if #results == 0 then
    return "No matches for pattern: " .. pattern, false
  end

  local output = table.concat(results, "\n")
  if #results >= MAX_GREP_RESULTS then
    output = output .. "\n\n(Results limited to " .. MAX_GREP_RESULTS .. " entries)"
  end

  return output, false
end

-------------------------------------------------------------------
-- Tool: Fetch
-------------------------------------------------------------------
local function executeFetch(input)
  local url = input.url
  if not url then return "Error: url is required", true end

  -- Delegate to the proxy server; its Python requests stack handles HTTPS
  -- correctly where OC's internet card has limited TLS support.
  local cfg = require("config").load()
  if not cfg.proxy_host or cfg.proxy_host == "" then
    return "Error: proxy not configured", true
  end

  local content, err = require("claude_api").fetch(cfg.proxy_host, cfg.proxy_port, cfg.proxy_token, url)
  if not content then
    return "Error fetching URL: " .. tostring(err), true
  end
  return content, false
end

-------------------------------------------------------------------
-- Helper: serialize a value to string (for hardware tool output)
-------------------------------------------------------------------
local function serializeResult(val)
  if val == nil then return "nil" end
  local t = type(val)
  if t == "string" or t == "number" or t == "boolean" then
    return tostring(val)
  elseif t == "table" then
    local ok, encoded = pcall(json.encode, val)
    if ok then return encoded end
    return tostring(val)
  end
  return tostring(val)
end

-------------------------------------------------------------------
-- Tool: Component (universal OC hardware access)
-------------------------------------------------------------------
local function executeComponent(input)
  local action = input.action
  if not action then return "Error: action required (list/call)", true end

  local comp = require("component")

  if action == "list" then
    local result = {}
    for addr, ctype in comp.list() do
      table.insert(result, ctype .. " " .. addr:sub(1, 8))
    end
    if #result == 0 then return "No components found", false end
    return table.concat(result, "\n"), false

  elseif action == "call" then
    local addr = input.address
    local method = input.method
    if not addr then return "Error: address required", true end
    if not method then return "Error: method required", true end

    local proxy
    local ok, err = pcall(function()
      -- Try as type name first, then as address
      if #addr <= 20 and not addr:match("%-") then
        local a = comp.list(addr)()
        if a then proxy = comp.proxy(a) end
      else
        proxy = comp.proxy(addr)
      end
    end)
    if not ok or not proxy then
      return "Error: component not found: " .. addr, true
    end
    if not proxy[method] then
      return "Error: no method: " .. method, true
    end

    local args = input.args or {}
    local results = {pcall(proxy[method], table.unpack(args))}
    if not results[1] then
      return "Error: " .. tostring(results[2]), true
    end

    local parts = {}
    for i = 2, #results do
      table.insert(parts, serializeResult(results[i]))
    end
    return table.concat(parts, "\n"), false
  end

  return "Error: unknown action: " .. tostring(action), true
end

-------------------------------------------------------------------
-- Tool: Inventory (read via transposer/adapter)
-------------------------------------------------------------------
local function executeInventory(input)
  local side = input.side
  if not side then return "Error: side required (0-5)", true end

  local comp = require("component")
  local proxy
  if comp.isAvailable("transposer") then
    proxy = comp.transposer
  elseif comp.isAvailable("inventory_controller") then
    proxy = comp.inventory_controller
  else
    return "Error: no transposer or inventory controller", true
  end

  if input.slot then
    local ok, stack = pcall(proxy.getStackInSlot, side, input.slot)
    if not ok then return "Error: " .. tostring(stack), true end
    if not stack then return "Slot " .. input.slot .. ": empty", false end
    return "Slot " .. input.slot .. ": " .. serializeResult(stack), false
  end

  local ok, size = pcall(proxy.getInventorySize, side)
  if not ok or not size then
    return "Error: no inventory on side " .. side, true
  end

  local items = {}
  local count = 0
  for i = 1, size do
    local sok, stack = pcall(proxy.getStackInSlot, side, i)
    if sok and stack then
      count = count + 1
      local label = stack.label or stack.name or "?"
      local qty = stack.size or 1
      table.insert(items, "Slot " .. i .. ": " .. label .. " x" .. qty)
      if count >= 54 then
        table.insert(items, "(... more slots)")
        break
      end
    end
  end

  if count == 0 then
    return "Inventory side " .. side .. ": " .. size .. " slots, all empty", false
  end
  return "Inventory (" .. size .. " slots, " .. count .. " items):\n" .. table.concat(items, "\n"), false
end

-------------------------------------------------------------------
-- Tool: Redstone (read/set signals)
-------------------------------------------------------------------
local function executeRedstone(input)
  local action = input.action
  local side = input.side
  if not action then return "Error: action required (get/set)", true end
  if not side then return "Error: side required (0-5)", true end

  local comp = require("component")
  if not comp.isAvailable("redstone") then
    return "Error: no redstone card/block", true
  end
  local rs = comp.redstone

  if action == "get" then
    local ok, val = pcall(rs.getInput, side)
    if not ok then return "Error: " .. tostring(val), true end
    return "Redstone input side " .. side .. ": " .. tostring(val), false
  elseif action == "set" then
    local value = input.value
    if not value then return "Error: value required (0-15)", true end
    local ok, err = pcall(rs.setOutput, side, value)
    if not ok then return "Error: " .. tostring(err), true end
    return "Redstone output side " .. side .. " set to " .. value, false
  end
  return "Error: unknown action: " .. tostring(action), true
end

-------------------------------------------------------------------
-- Tool: ME (AE2/ME system)
-------------------------------------------------------------------
local function executeME(input)
  local action = input.action
  if not action then return "Error: action required (items/craft/status)", true end

  local comp = require("component")
  local me
  for _, name in ipairs({"me_controller", "me_interface", "me_exportbus"}) do
    if comp.isAvailable(name) then
      me = comp[name]
      break
    end
  end
  if not me then return "Error: no ME bridge component", true end

  if action == "items" then
    local ok, items = pcall(me.getItemsInNetwork or me.getAvailableItems)
    if not ok then return "Error: " .. tostring(items), true end
    if not items then return "No items in ME system", false end

    local filter = input.filter and input.filter:lower()
    local results = {}
    local count = 0
    for _, item in ipairs(items) do
      local label = item.label or item.name or "?"
      if not filter or label:lower():find(filter, 1, true) then
        count = count + 1
        table.insert(results, label .. " x" .. (item.size or 0))
        if count >= 50 then
          table.insert(results, "(... use filter for more)")
          break
        end
      end
    end
    if count == 0 then
      return filter and ("No items matching '" .. filter .. "'") or "ME system empty", false
    end
    return table.concat(results, "\n"), false

  elseif action == "craft" then
    local item = input.item
    local craftCount = input.count or 1
    if not item then return "Error: item name required", true end

    local ok, items = pcall(me.getItemsInNetwork or me.getAvailableItems)
    if not ok then return "Error: " .. tostring(items), true end

    local target
    for _, c in ipairs(items or {}) do
      if (c.label or ""):lower() == item:lower() or (c.name or ""):lower() == item:lower() then
        target = c
        break
      end
    end
    if not target then return "Error: item not found: " .. item, true end

    local cOk, cRes = pcall(me.requestCrafting or me.craftItem, target, craftCount)
    if not cOk then return "Error: " .. tostring(cRes), true end
    return "Crafting requested: " .. (target.label or item) .. " x" .. craftCount, false

  elseif action == "status" then
    local results = {}
    local ok, items = pcall(me.getItemsInNetwork or me.getAvailableItems)
    if ok and items then
      table.insert(results, "Item types: " .. #items)
    end
    local eOk, energy = pcall(me.getAvgPowerUsage or function() return nil end)
    if eOk and energy then
      table.insert(results, "Avg power: " .. tostring(energy))
    end
    if #results == 0 then return "ME connected (no details available)", false end
    return table.concat(results, "\n"), false
  end
  return "Error: unknown action: " .. tostring(action), true
end

-------------------------------------------------------------------
-- Tool: Robot (movement and interaction)
-------------------------------------------------------------------
local function executeRobot(input)
  local action = input.action
  if not action then return "Error: action required", true end

  local ok, robot = pcall(require, "robot")
  if not ok then return "Error: robot API not available (not a robot?)", true end

  local dir = input.direction or "forward"

  if action == "move" then
    local fn = dir == "up" and robot.up or dir == "down" and robot.down or robot.forward
    local moved, reason = fn()
    return moved and ("Moved " .. dir) or ("Cannot move " .. dir .. ": " .. tostring(reason)), not moved

  elseif action == "turn" then
    local side = input.side or "left"
    if side == "right" then robot.turnRight() else robot.turnLeft() end
    return "Turned " .. side, false

  elseif action == "swing" then
    local fn = dir == "up" and robot.swingUp or dir == "down" and robot.swingDown or robot.swing
    local hit = fn()
    return hit and ("Swung " .. dir) or ("Nothing to swing at " .. dir), false

  elseif action == "place" then
    local fn = dir == "up" and robot.placeUp or dir == "down" and robot.placeDown or robot.place
    local placed, reason = fn()
    return placed and ("Placed " .. dir) or ("Cannot place " .. dir .. ": " .. tostring(reason)), not placed

  elseif action == "use" then
    local fn = dir == "up" and robot.useUp or dir == "down" and robot.useDown or robot.use
    local used = fn()
    return used and ("Used " .. dir) or ("Use failed " .. dir), false

  elseif action == "detect" then
    local fn = dir == "up" and robot.detectUp or dir == "down" and robot.detectDown or robot.detect
    return "Block " .. dir .. ": " .. (fn() and "present" or "empty"), false

  elseif action == "inspect" then
    local comp = require("component")
    if not comp.isAvailable("geolyzer") then
      return "Error: geolyzer needed for inspect", true
    end
    local x, y, z = 0, 0, 0
    if dir == "up" then y = 1 elseif dir == "down" then y = -1 else z = 1 end
    local iOk, info = pcall(comp.geolyzer.analyze, x, z, y)
    if not iOk then return "Error: " .. tostring(info), true end
    return serializeResult(info), false

  elseif action == "suck" then
    local fn = dir == "up" and robot.suckUp or dir == "down" and robot.suckDown or robot.suck
    local count = input.slot
    local sucked = count and fn(count) or fn()
    return sucked and "Picked up items" or "Nothing to pick up", false

  elseif action == "drop" then
    local fn = dir == "up" and robot.dropUp or dir == "down" and robot.dropDown or robot.drop
    local count = input.slot
    local dropped = count and fn(count) or fn()
    return dropped and "Dropped items" or "Nothing to drop", not dropped

  elseif action == "inventory" then
    local size = robot.inventorySize()
    local items = {}
    local count = 0
    for i = 1, size do
      local stack = robot.count(i)
      if stack > 0 then
        count = count + 1
        local label = "item"
        local comp = require("component")
        if comp.isAvailable("inventory_controller") then
          local iOk, info = pcall(comp.inventory_controller.getStackInInternalSlot, i)
          if iOk and info then label = info.label or info.name or "item" end
        end
        table.insert(items, "Slot " .. i .. ": " .. label .. " x" .. stack)
      end
    end
    if count == 0 then return "Robot inventory: " .. size .. " slots, empty", false end
    return "Robot (" .. count .. "/" .. size .. " used):\n" .. table.concat(items, "\n"), false
  end

  return "Error: unknown action: " .. tostring(action), true
end

-------------------------------------------------------------------
-- Tool: Scan (geolyzer terrain scanning + navigation)
-------------------------------------------------------------------
local function executeScan(input)
  local action = input.action
  if not action then return "Error: action required (block/area/position)", true end

  local comp = require("component")

  if action == "block" then
    if not comp.isAvailable("geolyzer") then
      return "Error: no geolyzer installed", true
    end
    local x = input.x or 0
    local y = input.y or 0
    local z = input.z or 0
    local ok, info = pcall(comp.geolyzer.analyze, x, z, y)
    if not ok then return "Error: " .. tostring(info), true end
    return serializeResult(info), false

  elseif action == "area" then
    if not comp.isAvailable("geolyzer") then
      return "Error: no geolyzer installed", true
    end
    local x = input.x or -4
    local z = input.z or -4
    local y = input.y or -1
    local w = input.w or 8
    local d = input.d or 8
    local h = input.h or 1
    -- Clamp to reasonable size
    if w * d * h > 512 then
      return "Error: volume too large (max 512 blocks, got " .. (w*d*h) .. ")", true
    end
    local ok, data = pcall(comp.geolyzer.scan, x, z, y, w, d, h)
    if not ok then return "Error: " .. tostring(data), true end
    -- data is a flat array of hardness values
    local result = "Scan " .. w .. "x" .. d .. "x" .. h .. " at (" .. x .. "," .. y .. "," .. z .. "):\n"
    local count = 0
    local air = 0
    local solid = 0
    for _, v in ipairs(data) do
      if v == 0 then air = air + 1 else solid = solid + 1 end
      count = count + 1
    end
    result = result .. count .. " blocks: " .. solid .. " solid, " .. air .. " air"
    -- Include raw data if small enough
    if count <= 64 then
      result = result .. "\nRaw hardness: " .. serializeResult(data)
    end
    return result, false

  elseif action == "position" then
    if not comp.isAvailable("navigation") then
      return "Error: no navigation upgrade installed", true
    end
    local ok, x, y, z = pcall(comp.navigation.getPosition)
    if not ok then return "Error: " .. tostring(x), true end
    local fOk, facing = pcall(comp.navigation.getFacing)
    local facingStr = ""
    if fOk and facing then
      local dirs = {[2]="north",[3]="south",[4]="west",[5]="east"}
      facingStr = " facing " .. (dirs[facing] or tostring(facing))
    end
    return "Position: " .. tostring(x) .. ", " .. tostring(y) .. ", " .. tostring(z) .. facingStr, false
  end

  return "Error: unknown action: " .. tostring(action), true
end

-------------------------------------------------------------------
-- Tool dispatcher
-------------------------------------------------------------------
local EXECUTORS = {
  Read = executeRead,
  Write = executeWrite,
  Edit = executeEdit,
  Run = executeRun,
  Glob = executeGlob,
  Grep = executeGrep,
  Fetch = executeFetch,
  Component = executeComponent,
  Inventory = executeInventory,
  Redstone = executeRedstone,
  ME = executeME,
  Robot = executeRobot,
  Scan = executeScan,
}

function tools.executeTool(name, input)
  local executor = EXECUTORS[name]
  if not executor then
    return "Error: Unknown tool: " .. tostring(name), true
  end

  local ok, result, isError = pcall(executor, input or {})
  if not ok then
    return "Error executing " .. name .. ": " .. tostring(result), true
  end

  return result, isError
end

return tools
