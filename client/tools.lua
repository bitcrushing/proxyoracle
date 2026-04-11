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
  }
}

-- Tools that require user confirmation before execution
local CONFIRM_TOOLS = {Write = true, Edit = true, Run = true}

function tools.needsConfirmation(name)
  return CONFIRM_TOOLS[name] == true
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

  -- Execute with output redirect
  local fullCmd = command .. " > " .. outFile .. " 2>&1"
  local success = shell.execute(fullCmd)

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
    return "Error: Directory not found: " .. basePath, true
  end

  local matches = {}

  walkDirectory(basePath, function(fullPath, isDir)
    if #matches >= MAX_GLOB_RESULTS then return end

    -- Get path relative to basePath for matching
    local relPath = fullPath
    if basePath ~= "/" then
      if fullPath:sub(1, #basePath) == basePath then
        relPath = fullPath:sub(#basePath + 1)
        if relPath:sub(1, 1) == "/" then
          relPath = relPath:sub(2)
        end
      end
    end

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
local MAX_FETCH_BYTES = 4096  -- 4KB cap for fetched content

local function executeFetch(input)
  local url = input.url
  if not url then return "Error: url is required", true end

  local component = require("component")
  if not component.isAvailable("internet") then
    return "Error: No internet card", true
  end

  local internet = require("internet")

  -- Fetch content
  local chunks = {}
  local totalBytes = 0
  local truncated = false

  local ok, err = pcall(function()
    for chunk in internet.request(url) do
      totalBytes = totalBytes + #chunk
      if totalBytes <= MAX_FETCH_BYTES then
        table.insert(chunks, chunk)
      else
        truncated = true
      end
    end
  end)

  if not ok then
    return "Error fetching URL: " .. tostring(err), true
  end

  local content = table.concat(chunks)
  chunks = nil

  if #content == 0 then
    return "Error: Empty response from " .. url, true
  end

  -- Strip HTML tags if content looks like HTML
  if content:match("^%s*<!") or content:match("^%s*<html") or content:match("<head") then
    -- Remove script and style blocks entirely
    content = content:gsub("<script[^>]*>.-</script>", "")
    content = content:gsub("<style[^>]*>.-</style>", "")
    -- Replace br/p/div/li/tr with newlines
    content = content:gsub("<br[^>]*>", "\n")
    content = content:gsub("</p>", "\n")
    content = content:gsub("</div>", "\n")
    content = content:gsub("</li>", "\n")
    content = content:gsub("</tr>", "\n")
    -- Strip remaining tags
    content = content:gsub("<[^>]+>", "")
    -- Decode common HTML entities
    content = content:gsub("&amp;", "&")
    content = content:gsub("&lt;", "<")
    content = content:gsub("&gt;", ">")
    content = content:gsub("&quot;", '"')
    content = content:gsub("&#39;", "'")
    content = content:gsub("&nbsp;", " ")
    -- Collapse whitespace
    content = content:gsub("[ \t]+", " ")
    content = content:gsub("\n%s*\n%s*\n", "\n\n")
    content = content:match("^%s*(.-)%s*$") or content
  end

  -- Final truncation after stripping
  if #content > MAX_FETCH_BYTES then
    content = content:sub(1, MAX_FETCH_BYTES)
    truncated = true
  end

  if truncated then
    content = content .. "\n\n(Truncated, was " .. totalBytes .. " bytes)"
  end

  return content, false
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
