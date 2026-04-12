-- Claude API client for OpenComputers (ProxyOracle thin client)
-- Communicates with ProxyOracle proxy server over plain HTTP.
-- No TLS, no conversation storage, no data card required.

local component = require("component")
local json = require("json")

local api = {}

-- Check if internet card is available
function api.checkInternet()
  if not component.isAvailable("internet") then
    return false, "No internet card found."
  end
  return true
end

-- Create raw TCP socket and wait for connection
local function createSocket(host, port, timeout)
  local internet = component.internet
  local sock, err = internet.connect(host, port)

  if not sock then
    return nil, "Failed to connect: " .. tostring(err)
  end

  timeout = timeout or 15
  local startTime = os.time()

  while true do
    local connected, connectErr = sock.finishConnect()
    if connected then
      return sock
    end
    if connected == nil then
      return nil, "Connection failed: " .. tostring(connectErr)
    end
    if os.time() - startTime > timeout then
      sock.close()
      return nil, "Connection timeout"
    end
    os.sleep(0.1)
  end
end

-- Write data to a raw socket
local function socketWrite(sock, data)
  local sent = 0
  while sent < #data do
    local chunk = data:sub(sent + 1, sent + 4096)
    local n, err = sock.write(chunk)
    if not n then return nil, err end
    sent = sent + n
  end
  return true
end

-- Build and send an HTTP request
local function sendHttpRequest(sock, method, path, host, token, body)
  local bodyStr = body and json.encode(body) or ""

  local lines = {
    method .. " " .. path .. " HTTP/1.1",
    "Host: " .. host,
    "Content-Type: application/json",
    "Authorization: Bearer " .. token,
    "Connection: close",
  }

  if #bodyStr > 0 then
    table.insert(lines, "Content-Length: " .. #bodyStr)
  end

  table.insert(lines, "")
  table.insert(lines, bodyStr)

  local request = table.concat(lines, "\r\n")
  return socketWrite(sock, request)
end

-- Line reader: buffers raw socket reads, yields complete lines
local function createLineReader(sock, timeout)
  local buffer = ""
  local readTimeout = timeout or 120
  local startTime = os.time()
  local closed = false

  return function()
    while true do
      local nlPos = buffer:find("\n")
      if nlPos then
        local line = buffer:sub(1, nlPos - 1)
        if #line > 0 and line:sub(-1) == "\r" then
          line = line:sub(1, -2)
        end
        buffer = buffer:sub(nlPos + 1)
        return line
      end

      if closed then
        if #buffer > 0 then
          local line = buffer
          buffer = ""
          return line
        end
        return nil
      end

      local chunk, readErr = sock.read(2048)
      if chunk then
        buffer = buffer .. chunk
        startTime = os.time()
      elseif readErr then
        local errStr = tostring(readErr)
        if errStr:find("[Cc]lose") then
          closed = true
        else
          if #buffer == 0 then
            return nil, "Read error: " .. errStr
          end
          closed = true
        end
      else
        if os.time() - startTime > readTimeout then
          return nil, "Read timeout"
        end
        os.sleep(0.05)
      end
    end
  end
end

-- Process SSE stream events from proxy (same format as Anthropic API).
-- Thinking events are already filtered by the proxy.
local function processSSEStream(readLine, onText, onToolUse)
  local currentEvent = nil
  local fullText = {}
  local contentBlocks = {}
  local jsonAccumulator = {}
  local usage = {input_tokens = 0, output_tokens = 0}
  local stopReason = nil
  local errorMsg = nil

  while true do
    local line, err = readLine()

    if line == nil then
      if err then errorMsg = err end
      break
    end

    -- Skip chunked encoding frame markers
    if line:match("^%x+$") then
      -- chunk size line

    elseif line == "" then
      currentEvent = nil

    elseif line:sub(1, 6) == "event:" then
      currentEvent = line:sub(7):match("^%s*(.*)")

    elseif line:sub(1, 5) == "data:" then
      local dataStr = line:sub(6):match("^%s*(.*)")

      if currentEvent == "message_start" then
        local ok, data = pcall(json.decode, dataStr)
        if ok and data and data.message and data.message.usage then
          usage.input_tokens = data.message.usage.input_tokens or 0
        end

      elseif currentEvent == "content_block_start" then
        local ok, data = pcall(json.decode, dataStr)
        if ok and data and data.content_block then
          local block = data.content_block
          local idx = data.index
          if block.type == "tool_use" then
            contentBlocks[idx] = {
              type = "tool_use",
              id = block.id or "",
              name = block.name or "",
              input = {}
            }
            jsonAccumulator = {}
            if onToolUse then
              onToolUse("start", block.name, block.id)
            end
          elseif block.type == "text" then
            contentBlocks[idx] = {type = "text", text = ""}
          end
        end

      elseif currentEvent == "content_block_delta" then
        local ok, data = pcall(json.decode, dataStr)
        if ok and data and data.delta then
          if data.delta.type == "text_delta" then
            local text = data.delta.text
            if text and text ~= "" then
              table.insert(fullText, text)
              local block = contentBlocks[data.index]
              if block and block.type == "text" then
                block.text = block.text .. text
              end
              if onText then
                onText(text)
              end
            end
          elseif data.delta.type == "input_json_delta" then
            if data.delta.partial_json then
              table.insert(jsonAccumulator, data.delta.partial_json)
            end
          end
        end

      elseif currentEvent == "content_block_stop" then
        local ok, data = pcall(json.decode, dataStr)
        if ok and data then
          local idx = data.index
          local block = contentBlocks[idx]
          if block and block.type == "tool_use" then
            local fullJson = table.concat(jsonAccumulator)
            if fullJson ~= "" then
              local jsonOk, parsed = pcall(json.decode, fullJson)
              if jsonOk and type(parsed) == "table" then
                block.input = parsed
              end
            end
            jsonAccumulator = {}
          end
        end

      elseif currentEvent == "message_delta" then
        local ok, data = pcall(json.decode, dataStr)
        if ok and data then
          if data.usage then
            usage.output_tokens = data.usage.output_tokens or 0
          end
          if data.delta and data.delta.stop_reason then
            stopReason = data.delta.stop_reason
          end
        end

      elseif currentEvent == "message_stop" then
        break

      elseif currentEvent == "error" then
        local ok, data = pcall(json.decode, dataStr)
        if ok and data and data.error then
          errorMsg = data.error.message or data.error.type or "Stream error"
        else
          errorMsg = "Stream error"
        end
        break
      end
    end
  end

  if errorMsg and #fullText == 0 then
    return nil, nil, errorMsg
  end

  usage.stop_reason = stopReason

  -- Build ordered content array
  local orderedContent = {}
  local maxIdx = -1
  for idx in pairs(contentBlocks) do
    if idx > maxIdx then maxIdx = idx end
  end
  for i = 0, maxIdx do
    if contentBlocks[i] then
      table.insert(orderedContent, contentBlocks[i])
    end
  end

  local text = table.concat(fullText)
  if #orderedContent == 0 and text ~= "" then
    orderedContent = {{type = "text", text = text}}
  end

  local result = {
    text = text,
    content = orderedContent,
    stop_reason = stopReason or "end_turn"
  }

  return result, usage, errorMsg
end

-- Read HTTP response status + headers, then stream SSE body
local function sendAndStream(sock, method, path, host, token, body, onText, onToolUse)
  local writeOk, writeErr = sendHttpRequest(sock, method, path, host, token, body)
  if not writeOk then
    sock.close()
    return nil, "Failed to send: " .. tostring(writeErr)
  end

  local readLine = createLineReader(sock, 120)

  -- Read HTTP status line
  local statusLine, statusErr = readLine()
  if not statusLine then
    sock.close()
    return nil, "No response: " .. tostring(statusErr)
  end

  local _, statusCode = statusLine:match("^(HTTP/%d%.%d)%s+(%d+)")
  statusCode = tonumber(statusCode)

  -- Read headers
  while true do
    local hline = readLine()
    if not hline or hline == "" then break end
  end

  -- Non-200: read error body
  if not statusCode or statusCode ~= 200 then
    local errParts = {}
    while true do
      local l = readLine()
      if not l then break end
      if not l:match("^%x+$") then
        table.insert(errParts, l)
      end
    end
    sock.close()
    local errBody = table.concat(errParts, "\n")
    local errorMsg = "Proxy error " .. (statusCode or "?")
    local ok, errData = pcall(json.decode, errBody)
    if ok and errData and errData.error then
      errorMsg = errorMsg .. ": " .. tostring(errData.error.message or errData.error.type)
    end
    return nil, errorMsg
  end

  -- Stream SSE
  local result, usage, streamErr = processSSEStream(readLine, onText, onToolUse)
  sock.close()

  if not result then
    return nil, streamErr or "Streaming failed"
  end

  return result, nil, usage
end

-- Create a new session on the proxy
function api.createSession(host, port, token, cfg)
  local sock, err = createSocket(host, port)
  if not sock then return nil, err end

  local writeOk, writeErr = sendHttpRequest(sock, "POST", "/session", host, token, {
    model = cfg.model,
    max_tokens = cfg.max_tokens,
    system_prompt = cfg.system_prompt,
  })

  if not writeOk then
    sock.close()
    return nil, "Failed to send: " .. tostring(writeErr)
  end

  local readLine = createLineReader(sock, 15)
  local statusLine = readLine()
  if not statusLine then
    sock.close()
    return nil, "No response from proxy"
  end

  local _, statusCode = statusLine:match("^(HTTP/%d%.%d)%s+(%d+)")
  statusCode = tonumber(statusCode)

  -- Read headers
  while true do
    local hline = readLine()
    if not hline or hline == "" then break end
  end

  -- Read body
  local bodyParts = {}
  while true do
    local l = readLine()
    if not l then break end
    if not l:match("^%x+$") then
      table.insert(bodyParts, l)
    end
  end
  sock.close()

  local body = table.concat(bodyParts, "\n")
  local ok, data = pcall(json.decode, body)

  if not ok or not data then
    return nil, "Invalid proxy response"
  end

  if statusCode ~= 200 then
    local msg = data.error and data.error.message or "Session creation failed"
    return nil, msg
  end

  return data.session_id
end

-- Send a user message and stream the response
function api.sendMessage(host, port, token, sessionId, text, onText, onToolUse)
  local sock, err = createSocket(host, port)
  if not sock then return nil, err end

  return sendAndStream(sock, "POST", "/session/" .. sessionId .. "/message",
    host, token, {text = text}, onText, onToolUse)
end

-- Send tool results and stream the next response
function api.sendToolResult(host, port, token, sessionId, results, onText, onToolUse)
  local sock, err = createSocket(host, port)
  if not sock then return nil, err end

  return sendAndStream(sock, "POST", "/session/" .. sessionId .. "/tool_result",
    host, token, {results = results}, onText, onToolUse)
end

-- Fetch session history from proxy
function api.getHistory(host, port, token, sessionId)
  local sock, err = createSocket(host, port)
  if not sock then return nil, err end

  local writeOk, writeErr = sendHttpRequest(sock, "GET", "/session/" .. sessionId .. "/history", host, token)
  if not writeOk then
    sock.close()
    return nil, writeErr
  end

  local readLine = createLineReader(sock, 15)
  local statusLine = readLine()
  if not statusLine then
    sock.close()
    return nil, "No response"
  end

  -- Read headers
  while true do
    local hline = readLine()
    if not hline or hline == "" then break end
  end

  -- Read body
  local bodyParts = {}
  while true do
    local l = readLine()
    if not l then break end
    if not l:match("^%x+$") then
      table.insert(bodyParts, l)
    end
  end
  sock.close()

  local body = table.concat(bodyParts, "\n")
  local ok, data = pcall(json.decode, body)
  if not ok or not data then
    return nil, "Invalid response"
  end

  return data
end

-- Delete a session
function api.deleteSession(host, port, token, sessionId)
  local sock, err = createSocket(host, port)
  if not sock then return end

  sendHttpRequest(sock, "DELETE", "/session/" .. sessionId, host, token)
  -- Read and discard response
  local readLine = createLineReader(sock, 5)
  while readLine() do end
  sock.close()
end

return api
