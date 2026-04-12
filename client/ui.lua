-- Terminal UI utilities for Claude Code
-- Handles display, input, and formatting

local component = require("component")
local term = require("term")
local event = require("event")

local ui = {}

-- Get terminal dimensions
function ui.getSize()
  local gpu = term.gpu()
  if gpu then
    return gpu.getViewport()
  end
  return 80, 25 -- Default fallback
end

-- Set colors if available
function ui.setColors(fg, bg)
  local gpu = term.gpu()
  if gpu then
    if fg then pcall(gpu.setForeground, fg) end
    if bg then pcall(gpu.setBackground, bg) end
  end
end

-- Reset colors to default
function ui.resetColors()
  local gpu = term.gpu()
  if gpu then
    pcall(gpu.setForeground, 0xFFFFFF)
    pcall(gpu.setBackground, 0x000000)
  end
end

-- Color constants
ui.colors = {
  white = 0xFFFFFF,
  black = 0x000000,
  gray = 0x888888,
  blue = 0x4444FF,
  green = 0x44FF44,
  red = 0xFF4444,
  yellow = 0xFFFF44,
  cyan = 0x44FFFF,
  orange = 0xFF8844
}

-- Print with color
function ui.printColored(text, color)
  ui.setColors(color)
  print(text)
  ui.resetColors()
end

-- Print header/banner
function ui.printHeader()
  local width = ui.getSize()
  local banner = "Claude Code for OpenComputers"
  local padding = math.floor((width - #banner) / 2)

  print("")
  ui.setColors(ui.colors.cyan)
  print(string.rep(" ", padding) .. banner)
  ui.resetColors()
  ui.setColors(ui.colors.gray)
  print(string.rep("-", width))
  ui.resetColors()
  print("")
end

-- Print prompt for user input
function ui.printPrompt()
  ui.setColors(ui.colors.green)
  io.write("> ")
  ui.resetColors()
end

-- Print Claude's response label (ensure it starts on a new line)
function ui.printResponseLabel()
  io.write("\n")
  ui.setColors(ui.colors.cyan)
  print("Claude:")
  ui.resetColors()
end

-- Print error message
function ui.printError(msg)
  ui.setColors(ui.colors.red)
  print("Error: " .. tostring(msg))
  ui.resetColors()
end

-- Print info message
function ui.printInfo(msg)
  ui.setColors(ui.colors.gray)
  print(msg)
  ui.resetColors()
end

-- Print success message
function ui.printSuccess(msg)
  ui.setColors(ui.colors.green)
  print(msg)
  ui.resetColors()
end

-- Print token usage after a response
function ui.printTokenUsage(input, output, contextPct, freeKB, totalKB)
  ui.setColors(ui.colors.gray)
  local info = "[" .. input .. " in / " .. output .. " out"
  if contextPct then
    info = info .. " | ctx: " .. string.format("%.0f%%", contextPct)
  end
  if freeKB and totalKB then
    info = info .. " | ram: " .. freeKB .. "/" .. totalKB .. "KB"
  end
  info = info .. "]"
  print(info)
  ui.resetColors()
end

-- Print context window warning
function ui.printContextWarning(pct, used, limit)
  ui.setColors(ui.colors.orange)
  print("Warning: Context " .. string.format("%.0f%%", pct) .. " full (" .. used .. "/" .. limit .. " tokens)")
  print("Use /compact to free space or /clear to start fresh.")
  ui.resetColors()
end

-- Word wrap text to fit screen width
function ui.wordWrap(text, maxWidth)
  maxWidth = maxWidth or ui.getSize()
  local lines = {}

  for line in text:gmatch("[^\n]*") do
    if #line <= maxWidth then
      table.insert(lines, line)
    else
      -- Wrap long lines using table accumulation (avoids O(n) string concat)
      local words = {}
      local currentLen = 0
      for word in line:gmatch("%S+") do
        local wordLen = #word
        local sep = currentLen > 0 and 1 or 0
        if currentLen + wordLen + sep <= maxWidth then
          table.insert(words, word)
          currentLen = currentLen + wordLen + sep
        else
          if currentLen > 0 then
            table.insert(lines, table.concat(words, " "))
            words = {}
            currentLen = 0
          end
          -- Handle very long words
          while #word > maxWidth do
            table.insert(lines, word:sub(1, maxWidth))
            word = word:sub(maxWidth + 1)
          end
          words = {word}
          currentLen = #word
        end
      end
      if currentLen > 0 then
        table.insert(lines, table.concat(words, " "))
      elseif #lines == 0 or lines[#lines] ~= "" then
        table.insert(lines, "")
      end
    end
  end

  return table.concat(lines, "\n")
end

-- Print response with word wrapping and pagination for long messages
function ui.printResponse(text)
  local width, height = ui.getSize()
  local wrapped = ui.wordWrap(text, width - 2)

  -- Split into lines
  local lines = {}
  for line in wrapped:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end

  -- Remove trailing empty line from pattern match
  if lines[#lines] == "" then
    table.remove(lines)
  end

  -- Calculate usable height (reserve line for prompt + pagination indicator)
  local pageSize = height - 2

  -- If fits on screen, just print
  if #lines <= pageSize then
    print(wrapped)
    return
  end

  -- Paginate long responses
  local totalPages = math.ceil(#lines / pageSize)
  local currentLine = 1
  while currentLine <= #lines do
    -- Print one page
    local endLine = math.min(currentLine + pageSize - 1, #lines)
    for i = currentLine, endLine do
      print(lines[i])
    end

    currentLine = endLine + 1

    -- If more content, show prompt
    if currentLine <= #lines then
      local remaining = #lines - currentLine + 1
      local currentPage = math.ceil((currentLine - 1) / pageSize)
      ui.setColors(ui.colors.yellow)
      io.write("-- Page " .. currentPage .. "/" .. totalPages .. " (" .. remaining .. " lines remaining) [Enter/q] --")
      ui.resetColors()

      -- Wait for keypress
      local _, _, char = event.pull("key_down")
      -- Clear the prompt line
      io.write("\r" .. string.rep(" ", width) .. "\r")

      -- Check for quit
      if char == 113 or char == 81 then -- 'q' or 'Q'
        ui.setColors(ui.colors.gray)
        print("(Response truncated)")
        ui.resetColors()
        break
      end
    end
  end
end

-- Read user input with history support
function ui.readInput(history)
  history = history or {}
  local input = term.read(history, false, nil, nil)
  if input then
    input = input:gsub("%s+$", "") -- Trim trailing whitespace/newline
  end
  return input
end

-- Confirm prompt
function ui.confirm(message)
  ui.setColors(ui.colors.yellow)
  io.write(message .. " (y/n): ")
  ui.resetColors()

  local input = ui.readInput()
  return input and (input:lower() == "y" or input:lower() == "yes")
end

-- Print tool use label during streaming (e.g. "[Glob] ")
function ui.printToolStart(toolName)
  ui.setColors(ui.colors.yellow)
  print("[" .. toolName .. "]")
  ui.resetColors()
end

-- Print details of what a tool will do (before confirmation)
function ui.printToolDetails(name, input)
  ui.setColors(ui.colors.gray)
  if name == "Read" then
    print("  Read: " .. tostring(input.file_path or "?"))
  elseif name == "Write" then
    local size = input.content and #input.content or 0
    print("  Write: " .. tostring(input.file_path or "?") .. " (" .. size .. " bytes)")
  elseif name == "Edit" then
    print("  Edit: " .. tostring(input.file_path or "?"))
    local preview = (input.old_string or ""):sub(1, 60):gsub("\n", "\\n")
    print("  Find: " .. preview .. (#(input.old_string or "") > 60 and "..." or ""))
  elseif name == "Run" then
    print("  Run: " .. tostring(input.command or "?"))
  elseif name == "Glob" then
    print("  Glob: " .. tostring(input.pattern or "?"))
  elseif name == "Grep" then
    print("  Grep: " .. tostring(input.pattern or "?"))
  elseif name == "Fetch" then
    print("  Fetch: " .. tostring(input.url or "?"))
  elseif name == "Component" then
    if input.action == "list" then
      print("  Component: list all")
    else
      print("  Component: " .. tostring(input.address or "?") .. "." .. tostring(input.method or "?"))
    end
  elseif name == "Inventory" then
    print("  Inventory: side " .. tostring(input.side or "?") .. (input.slot and (" slot " .. input.slot) or ""))
  elseif name == "Redstone" then
    print("  Redstone: " .. tostring(input.action or "?") .. " side " .. tostring(input.side or "?"))
  elseif name == "ME" then
    print("  ME: " .. tostring(input.action or "?") .. (input.filter and (" '" .. input.filter .. "'") or "") .. (input.item and (" " .. input.item) or ""))
  elseif name == "Robot" then
    print("  Robot: " .. tostring(input.action or "?") .. " " .. tostring(input.direction or input.side or ""))
  elseif name == "Scan" then
    print("  Scan: " .. tostring(input.action or "?"))
  end
  ui.resetColors()
end

-- Print brief executing indicator
function ui.printToolExecuting(name)
  ui.setColors(ui.colors.gray)
  io.write("  Running... ")
  ui.resetColors()
end

-- Print tool result summary
function ui.printToolResult(name, result, isError)
  local resultStr = tostring(result or "")
  if isError then
    ui.setColors(ui.colors.red)
    print(resultStr:sub(1, 120))
  else
    ui.setColors(ui.colors.green)
    local lineCount = 1
    for _ in resultStr:gmatch("\n") do lineCount = lineCount + 1 end
    local sizeStr = #resultStr > 1024
      and string.format("%.1fKB", #resultStr / 1024)
      or (#resultStr .. "B")
    print("Done (" .. lineCount .. " lines, " .. sizeStr .. ")")
  end
  ui.resetColors()
end

-- Auto mode display helpers
function ui.printAutoStart(goal)
  print("")
  ui.setColors(ui.colors.orange)
  print("=== AUTO MODE STARTED ===")
  ui.setColors(ui.colors.cyan)
  print("Goal: " .. goal)
  ui.setColors(ui.colors.gray)
  print("Press any key to interrupt.")
  ui.resetColors()
  print("")
end

function ui.printAutoIteration(iteration, goal)
  ui.setColors(ui.colors.orange)
  print("[Auto #" .. iteration .. "] " .. goal)
  ui.resetColors()
end

function ui.printAutoWaiting(seconds)
  ui.setColors(ui.colors.gray)
  print("[Auto] Waiting " .. seconds .. "s (press any key to stop)...")
  ui.resetColors()
end

function ui.printAutoEnd(reason)
  print("")
  ui.setColors(ui.colors.orange)
  print("=== AUTO MODE ENDED: " .. reason .. " ===")
  ui.resetColors()
  print("")
end

-- Print help information
function ui.printHelp()
  print("")
  ui.printColored("Commands:", ui.colors.cyan)
  print("  /help         - Show this help message")
  print("  /clear        - Clear conversation (new session)")
  print("  /auto <goal>  - Start autonomous mode")
  print("  /last         - Re-display last response (paginated)")
  print("  /history      - Show conversation summary")
  print("  /cost         - Show token usage and cost estimate")
  print("  /memory       - Show RAM usage")
  print("  /yolo         - Toggle auto-allow (skip confirmations)")
  print("  /setup        - Configure proxy connection")
  print("  /exit         - Exit")
  print("")
  ui.printColored("Tools:", ui.colors.cyan)
  print("  File: Read, Write, Edit, Run, Glob, Grep, Fetch")
  print("  Hardware: Component, Inventory, Redstone, ME, Robot, Scan")
  print("  Some tools require confirmation (use /yolo to skip).")
  print("")
  ui.printColored("Tips:", ui.colors.cyan)
  print("  - Press Ctrl+C to interrupt")
  print("  - Use arrow keys for input history")
  print("  - Responses stream in real-time")
  print("  - /auto runs Claude autonomously toward a goal")
  print("")
end

-- Clear screen
function ui.clear()
  term.clear()
end

return ui
