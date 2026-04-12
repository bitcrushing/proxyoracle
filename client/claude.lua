-- Claude Code for OpenComputers (ProxyOracle thin client)
-- Connects to a ProxyOracle proxy server for API access.
-- No TLS, no conversation storage, no data card required.
--
-- Installation:
--   1. Copy all .lua files to /usr/lib/ (or external drive)
--   2. Copy claude.lua to /usr/bin/claude
--   3. Run 'claude --setup' to configure proxy connection
--   4. Run 'claude' to start chatting!

local args = {...}

-- Add lib paths for requires
package.path = package.path .. ";/usr/lib/?.lua"

-- Auto-detect external drive install
local _fs = require("filesystem")
for proxy, mountPath in _fs.mounts() do
  if mountPath:sub(1, 5) == "/mnt/" then
    local testFile = _fs.concat(mountPath, "claude/config.lua")
    if _fs.exists(testFile) then
      local dirPath = _fs.concat(mountPath, "claude")
      package.path = package.path .. ";" .. dirPath .. "/?.lua"
      break
    end
  end
end

-- Snapshot loaded modules for cleanup on exit
local loadedAtStart = {}
for k in pairs(package.loaded) do
  loadedAtStart[k] = true
end

local config = require("config")
local api = require("claude_api")
local ui = require("ui")
local json = require("json")
local tools = require("tools")
local term = require("term")

-- Maximum tool-use loop iterations per user message
local MAX_TOOL_ITERATIONS = 25

-- Session state
local sessionId = nil
local inputHistory = {}
local lastResponseText = nil  -- Cache of last assistant response for /last
local runAutonomousLoop       -- forward declaration (defined after sendChat)
local sessionUsage = {
  total_input = 0,
  total_output = 0,
  request_count = 0,
  session_start = os.time()
}

-- Cleanup function
local function cleanup()
  -- Try to delete session on proxy
  if sessionId then
    local cfg = config.load()
    pcall(api.deleteSession, cfg.proxy_host, cfg.proxy_port, cfg.proxy_token, sessionId)
  end

  sessionId = nil
  inputHistory = nil
  sessionUsage = nil

  for k in pairs(package.loaded) do
    if not loadedAtStart[k] then
      package.loaded[k] = nil
    end
  end
end

-- Handle command line arguments
local function handleArgs()
  if #args == 0 then
    return "chat"
  end

  local arg = args[1]
  if arg == "--setup" or arg == "-s" then
    return "setup"
  elseif arg == "--help" or arg == "-h" then
    return "help"
  elseif arg == "--version" or arg == "-v" then
    return "version"
  else
    return "chat", table.concat(args, " ")
  end
end

-- Extract text from content (handles both string and content-array formats)
local function getTextFromContent(content)
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    local parts = {}
    for _, block in ipairs(content) do
      if type(block) == "table" then
        if block.type == "text" then
          table.insert(parts, block.text or "")
        elseif block.type == "tool_use" then
          table.insert(parts, "[" .. (block.name or "tool") .. "]")
        elseif block.type == "tool_result" then
          table.insert(parts, "[result]")
        end
      end
    end
    return table.concat(parts, " ")
  end
  return ""
end

-- Get a human-readable description for tool confirmation prompt
local function getToolDescription(name, input)
  if name == "Write" then
    local size = input.content and #input.content or 0
    return "write " .. tostring(input.file_path) .. " (" .. size .. " bytes)"
  elseif name == "Edit" then
    return "edit " .. tostring(input.file_path)
  elseif name == "Run" then
    return tostring(input.command)
  elseif name == "Component" then
    if input.action == "list" then return "list components" end
    return "call " .. tostring(input.address or "?") .. "." .. tostring(input.method or "?")
  elseif name == "Redstone" then
    return input.action .. " side " .. tostring(input.side) .. (input.value and (" = " .. input.value) or "")
  elseif name == "ME" then
    if input.action == "craft" then return "craft " .. tostring(input.item) .. " x" .. tostring(input.count or 1) end
    return "ME " .. tostring(input.action)
  elseif name == "Robot" then
    return tostring(input.action) .. " " .. tostring(input.direction or input.side or "")
  end
  return name
end

-- Execute a tool with permission check
local function executeToolWithPermission(block)
  local name = block.name
  local input = block.input or {}

  ui.printToolDetails(name, input)

  local cfg = config.load()
  if tools.needsConfirmation(name, input) and not cfg.auto_allow then
    local desc = getToolDescription(name, input)
    local response = ui.confirm("Allow " .. name .. "? " .. desc)
    if response == false then
      return {
        content = "Tool execution denied by user.",
        is_error = true
      }
    elseif type(response) == "string" then
      -- User provided feedback instead of approving
      return {
        content = "User feedback: " .. response,
        is_error = true
      }
    end
    -- response == true: proceed with execution
  end

  ui.printToolExecuting(name)
  local result, isError = tools.executeTool(name, input)

  ui.printToolResult(name, result, isError)

  return {
    content = result or "",
    is_error = isError == true
  }
end

-- Track token usage from SSE response
local function trackUsage(usage)
  if not usage or type(usage) ~= "table" then return end

  local inputTok = usage.input_tokens or 0
  local outputTok = usage.output_tokens or 0

  sessionUsage.total_input = sessionUsage.total_input + inputTok
  sessionUsage.total_output = sessionUsage.total_output + outputTok
  sessionUsage.request_count = sessionUsage.request_count + 1

  ui.printTokenUsage(inputTok, outputTok)
end

-- Process slash commands
local function processCommand(input)
  local cmd = input:match("^/(%S+)")
  local cmdArg = input:match("^/%S+%s+(.+)$")

  if cmd == "help" then
    ui.printHelp()
    return true

  elseif cmd == "clear" then
    -- Delete old session, create new one
    local cfg = config.load()
    if sessionId then
      api.deleteSession(cfg.proxy_host, cfg.proxy_port, cfg.proxy_token, sessionId)
    end
    local newId, err = api.createSession(cfg.proxy_host, cfg.proxy_port, cfg.proxy_token, cfg)
    if newId then
      sessionId = newId
      sessionUsage = {
        total_input = 0, total_output = 0,
        request_count = 0, session_start = os.time()
      }
      ui.printSuccess("Conversation cleared (new session).")
    else
      ui.printError("Failed to create new session: " .. tostring(err))
    end
    return true

  elseif cmd == "model" then
    local models = {
      sonnet = "claude-sonnet-4-6",
      opus = "claude-opus-4-6",
      haiku = "claude-haiku-4-5-20251001",
    }
    if cmdArg then
      local newModel = models[cmdArg:lower()] or cmdArg
      local cfg = config.load()
      cfg.model = newModel
      config.save(cfg)
      ui.printSuccess("Model set to: " .. newModel)
      ui.printInfo("Takes effect on next /clear or new session.")
    else
      local cfg = config.load()
      ui.printInfo("Current model: " .. cfg.model)
      ui.printInfo("Usage: /model sonnet | opus | haiku | <full-model-id>")
    end
    return true

  elseif cmd == "setup" then
    config.setup()
    return true

  elseif cmd == "exit" or cmd == "quit" or cmd == "q" then
    return false, "exit"

  elseif cmd == "cost" then
    local u = sessionUsage
    local elapsed = os.time() - u.session_start
    local minutes = math.floor(elapsed / 60)

    print("")
    ui.printColored("Session Usage:", ui.colors.cyan)
    print("  Requests:      " .. u.request_count)
    print("  Input tokens:  " .. u.total_input)
    print("  Output tokens: " .. u.total_output)
    print("  Total tokens:  " .. (u.total_input + u.total_output))
    print("  Session time:  " .. minutes .. " min")

    -- Estimate cost based on model
    local cfg = config.load()
    local model = cfg.model or "unknown"
    local inRate, outRate = 3, 15  -- Sonnet default $/MTok
    if model:find("opus") then
      inRate, outRate = 15, 75
    elseif model:find("haiku") then
      inRate, outRate = 0.25, 1.25
    end
    local cost = u.total_input * inRate / 1000000 + u.total_output * outRate / 1000000
    ui.setColors(ui.colors.yellow)
    print(string.format("  Est. cost:     $%.4f (%s)", cost, model))
    ui.resetColors()
    print("")
    return true

  elseif cmd == "yolo" then
    local cfg = config.load()
    cfg.auto_allow = not cfg.auto_allow
    config.save(cfg)
    if cfg.auto_allow then
      ui.printColored("Auto-allow ON — Write/Edit/Run will execute without confirmation.", ui.colors.orange)
    else
      ui.printSuccess("Auto-allow OFF — Write/Edit/Run will ask for confirmation.")
    end
    return true

  elseif cmd == "last" then
    if lastResponseText then
      ui.printResponseLabel()
      ui.printResponse(lastResponseText)
      print("")
    else
      ui.printInfo("No previous response to display.")
    end
    return true

  elseif cmd == "history" then
    local cfg = config.load()
    local data, err = api.getHistory(cfg.proxy_host, cfg.proxy_port, cfg.proxy_token, sessionId)
    if not data or not data.history then
      ui.printError(err or "Failed to fetch history")
      return true
    end
    if #data.history == 0 then
      ui.printInfo("No messages in history.")
    else
      for i, msg in ipairs(data.history) do
        local role = msg.role == "user" and "You" or "Claude"
        local preview = msg.preview or ""
        if #preview > 50 then preview = preview:sub(1, 50) .. "..." end
        ui.setColors(msg.role == "user" and ui.colors.green or ui.colors.cyan)
        print(role .. ": " .. preview)
        ui.resetColors()
      end
    end
    return true

  elseif cmd == "memory" or cmd == "mem" then
    local computer = require("computer")
    local free = computer.freeMemory()
    local total = computer.totalMemory()
    local used = total - free

    print("")
    ui.printColored("Memory:", ui.colors.cyan)
    print(string.format("  RAM: %dKB used / %dKB total (%dKB free)",
      math.floor(used / 1024), math.floor(total / 1024), math.floor(free / 1024)))
    print("  Conversation stored on proxy server")
    print("")
    return true

  elseif cmd == "auto" then
    if not cmdArg or cmdArg == "" then
      ui.printError("Usage: /auto <goal>")
      ui.printInfo("Example: /auto Monitor GT machines and alert if any stall")
      return true
    end
    runAutonomousLoop(cmdArg)
    return true

  else
    ui.printError("Unknown command: /" .. tostring(cmd))
    ui.printInfo("Type /help for available commands.")
    return true
  end
end

-- Main chat function with agentic tool-use loop
local function sendChat(userInput)
  local cfg = config.load()
  local iteration = 0
  local lastResult = nil

  while iteration < MAX_TOOL_ITERATIONS do
    iteration = iteration + 1

    ui.printResponseLabel()

    local firstChunk = true
    local responseChunks = {}

    local function onText(text)
      firstChunk = false
      table.insert(responseChunks, text)
      io.write(text)
    end

    local function onToolUse(evt, name, id)
      if evt == "start" then
        if not firstChunk then
          print("")
        end
        firstChunk = true
        ui.printToolStart(name)
      end
    end

    local result, err, usage

    if iteration == 1 then
      -- First iteration: send user message
      result, err, usage = api.sendMessage(
        cfg.proxy_host, cfg.proxy_port, cfg.proxy_token,
        sessionId, userInput, onText, onToolUse
      )
    else
      -- Subsequent iterations: send tool results
      local toolResults = {}
      for _, block in ipairs(lastResult.content) do
        if block.type == "tool_use" then
          local toolResult = executeToolWithPermission(block)
          table.insert(toolResults, {
            tool_use_id = block.id,
            content = toolResult.content,
            is_error = toolResult.is_error
          })
        end
      end

      result, err, usage = api.sendToolResult(
        cfg.proxy_host, cfg.proxy_port, cfg.proxy_token,
        sessionId, toolResults, onText, onToolUse
      )
    end

    if not firstChunk then
      print("")
    end

    if not result then
      ui.printError(err)
      return false
    end

    lastResult = result
    trackUsage(usage)

    -- Cache the last text response for /last command
    if #responseChunks > 0 then
      lastResponseText = table.concat(responseChunks)
    end

    -- Check if Claude wants to use more tools
    if result.stop_reason ~= "tool_use" then
      break
    end

    print("")
  end

  if iteration >= MAX_TOOL_ITERATIONS then
    ui.printError("Tool loop reached limit (" .. MAX_TOOL_ITERATIONS .. " iterations)")
  end

  print("")
  return true
end

-- Autonomous loop: Claude works toward a goal across multiple iterations.
-- Maintains top-level goal, current sub-goal, and progress log.
runAutonomousLoop = function(initialGoal)
  local event = require("event")
  local cfg = config.load()
  local autoInterval = cfg.auto_interval or 30
  local maxIter = cfg.max_auto_iterations or 50
  local topGoal = initialGoal
  local currentGoal = initialGoal
  local progressLog = {}  -- {iteration, summary} entries, max 10
  local iteration = 0

  ui.printAutoStart(topGoal)

  while iteration < maxIter do
    iteration = iteration + 1

    -- Build the auto-mode message with context anchors
    local msg
    if iteration == 1 then
      msg = "AUTO MODE\nTop Goal: " .. topGoal ..
        "\n\nYou are in autonomous mode. Work toward this goal using tools." ..
        "\nControl the loop with tags in your response:" ..
        "\n[NEXT_GOAL: text] - set sub-goal for next iteration" ..
        "\n[PROGRESS: summary] - log what you accomplished" ..
        "\n[WAIT: seconds] - override wait before next iteration" ..
        "\n[DONE] - task complete" ..
        "\n[PAUSE] - return to manual mode"
    else
      local logText = ""
      if #progressLog > 0 then
        local lines = {}
        for _, entry in ipairs(progressLog) do
          table.insert(lines, "- #" .. entry.iter .. ": " .. entry.summary)
        end
        logText = "\n\nProgress Log:\n" .. table.concat(lines, "\n")
      end
      msg = "AUTO MODE\nTop Goal: " .. topGoal ..
        "\nCurrent Step (iteration " .. iteration .. "): " .. currentGoal ..
        logText ..
        "\n\nWork toward the current step. Use [PROGRESS: ...] to log what you accomplish."
    end

    ui.printAutoIteration(iteration, currentGoal)
    local success = sendChat(msg)

    if not success then
      ui.printAutoEnd("Chat failed")
      break
    end

    -- Parse control tags from response
    local resp = lastResponseText or ""

    -- Extract progress
    local progress = resp:match("%[PROGRESS:%s*(.-)%]")
    if progress and progress ~= "" then
      table.insert(progressLog, {iter = iteration, summary = progress})
      -- Keep only last 10 entries
      while #progressLog > 10 do
        table.remove(progressLog, 1)
      end
    end

    if resp:find("%[DONE%]") then
      ui.printAutoEnd("Task complete")
      break
    end

    if resp:find("%[PAUSE%]") then
      ui.printAutoEnd("Paused")
      break
    end

    local nextGoal = resp:match("%[NEXT_GOAL:%s*(.-)%]")
    if nextGoal and nextGoal ~= "" then
      currentGoal = nextGoal
    end

    local waitOverride = resp:match("%[WAIT:%s*(%d+)%]")
    local waitTime = waitOverride and tonumber(waitOverride) or autoInterval

    -- Interruptible wait
    ui.printAutoWaiting(waitTime)
    local interrupted = false
    local waitEnd = os.time() + waitTime

    while os.time() < waitEnd do
      local evt = event.pull(0.5, "key_down")
      if evt then
        interrupted = true
        break
      end
    end

    if interrupted then
      ui.printAutoEnd("Interrupted by user")
      break
    end
  end

  if iteration >= maxIter then
    ui.printAutoEnd("Max iterations (" .. maxIter .. ")")
  end
end

-- Main loop
local function mainLoop(initialMessage)
  ui.clear()
  ui.printHeader()

  local cfg = config.load()
  if not cfg.proxy_host or cfg.proxy_host == "" then
    ui.printError("Proxy not configured.")
    ui.printInfo("Run 'claude --setup' to configure proxy connection.")
    print("")
    return
  end

  local hasInternet, internetErr = api.checkInternet()
  if not hasInternet then
    ui.printError(internetErr)
    return
  end

  -- Create session on proxy
  ui.printInfo("Connecting to proxy...")
  local id, err = api.createSession(cfg.proxy_host, cfg.proxy_port, cfg.proxy_token, cfg)
  if not id then
    ui.printError("Failed to connect: " .. tostring(err))
    return
  end
  sessionId = id
  ui.printSuccess("Connected (session: " .. id .. ")")

  ui.printInfo("Type /help for commands, /exit to quit.")
  ui.printInfo("Claude can read, write, and edit files on this computer.")
  print("")

  if initialMessage and initialMessage ~= "" then
    ui.printPrompt()
    print(initialMessage)
    sendChat(initialMessage)
  end

  while true do
    ui.printPrompt()
    local input = ui.readInput(inputHistory)

    if not input or input == "" then
      -- Empty input, continue
    elseif input:sub(1, 1) == "/" then
      local continue, action = processCommand(input)
      if action == "exit" then
        ui.printInfo("Goodbye!")
        break
      end
    else
      table.insert(inputHistory, input)
      sendChat(input)
    end
  end
end

-- Print version info
local function printVersion()
  print("Claude Code for OpenComputers v3.0.0 (ProxyOracle)")
  print("Powered by Anthropic's Claude API via ProxyOracle proxy")
end

-- Print usage help
local function printUsage()
  print("Usage: claude [options] [message]")
  print("")
  print("Options:")
  print("  --setup, -s    Configure proxy connection")
  print("  --help, -h     Show this help message")
  print("  --version, -v  Show version information")
  print("")
  print("Examples:")
  print("  claude                   Start interactive chat")
  print("  claude --setup           Configure settings")
  print("  claude \"Hello Claude!\"   Start with a message")
end

-- Entry point
local function main()
  local mode, initialMessage = handleArgs()

  if mode == "setup" then
    config.setup()
  elseif mode == "help" then
    printUsage()
  elseif mode == "version" then
    printVersion()
  elseif mode == "chat" then
    local ok, err = pcall(mainLoop, initialMessage)
    if not ok and err and not err:match("interrupted") then
      ui.printError(err)
    end
  end

  cleanup()
end

main()
