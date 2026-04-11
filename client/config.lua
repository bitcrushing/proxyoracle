-- Configuration handler for Claude Code (ProxyOracle)
-- Manages proxy connection and settings

local filesystem = require("filesystem")
local json = require("json")

local config = {}

local CONFIG_PATH = "/etc/claude.cfg"
local DEFAULT_CONFIG = {
  proxy_host = "",
  proxy_port = 8080,
  proxy_token = "",
  model = "claude-sonnet-4-6",
  max_tokens = 16384,
  system_prompt = "You are Claude on an OpenComputers Minecraft computer. Lua 5.3, forward slashes, working dir /home. Has internet card. Keep responses concise. Use absolute paths with tools. Note: lua -e is not available, write a temp .lua file instead."
}

-- Load configuration from file
function config.load()
  if not filesystem.exists(CONFIG_PATH) then
    return DEFAULT_CONFIG
  end

  local file, err = io.open(CONFIG_PATH, "r")
  if not file then
    return DEFAULT_CONFIG
  end

  local content = file:read("*a")
  file:close()

  local success, cfg = pcall(json.decode, content)
  if not success or type(cfg) ~= "table" then
    return DEFAULT_CONFIG
  end

  -- Merge with defaults
  for k, v in pairs(DEFAULT_CONFIG) do
    if cfg[k] == nil then
      cfg[k] = v
    end
  end

  return cfg
end

-- Save configuration to file
function config.save(cfg)
  if not filesystem.exists("/etc") then
    filesystem.makeDirectory("/etc")
  end

  local file, err = io.open(CONFIG_PATH, "w")
  if not file then
    return false, "Failed to open config file: " .. tostring(err)
  end

  file:write(json.encode(cfg))
  file:close()
  return true
end

-- Get a specific config value
function config.get(key)
  local cfg = config.load()
  return cfg[key]
end

-- Set a specific config value
function config.set(key, value)
  local cfg = config.load()
  cfg[key] = value
  return config.save(cfg)
end

-- Interactive setup
function config.setup()
  local term = require("term")

  term.clear()
  print("=== ProxyOracle Configuration ===")
  print("")
  print("Connect to your ProxyOracle proxy server.")
  print("Get the proxy host, port, and auth token from")
  print("your proxy server's proxy_config.json file.")
  print("")

  local cfg = config.load()

  -- Proxy host
  io.write("Proxy host")
  if cfg.proxy_host ~= "" then
    io.write(" [" .. cfg.proxy_host .. "]")
  end
  io.write(": ")
  local host = term.read()
  host = host and host:gsub("%s+$", "") or ""
  if host ~= "" then
    cfg.proxy_host = host
  end

  -- Proxy port
  io.write("Proxy port [" .. cfg.proxy_port .. "]: ")
  local port = term.read()
  port = port and port:gsub("%s+$", "") or ""
  if port ~= "" then
    local num = tonumber(port)
    if num then cfg.proxy_port = num end
  end

  -- Auth token
  io.write("Auth token")
  if cfg.proxy_token ~= "" then
    io.write(" [" .. cfg.proxy_token:sub(1, 8) .. "...]")
  end
  io.write(": ")
  local token = term.read()
  token = token and token:gsub("%s+$", "") or ""
  if token ~= "" then
    cfg.proxy_token = token
  end

  -- Model selection
  local models = {
    {id = "claude-sonnet-4-6", label = "Claude Sonnet 4.6 (default, balanced)"},
    {id = "claude-opus-4-6", label = "Claude Opus 4.6 (most capable)"},
    {id = "claude-haiku-4-5-20251001", label = "Claude Haiku 4.5 (fastest)"},
  }

  print("")
  print("Model selection:")
  for i, m in ipairs(models) do
    local current = (m.id == cfg.model) and " *" or ""
    print("  " .. i .. ". " .. m.label .. current)
    print("     " .. m.id)
  end
  io.write("Pick [1-" .. #models .. "] or type model ID [" .. cfg.model .. "]: ")
  local modelInput = term.read()
  modelInput = modelInput and modelInput:gsub("%s+$", "") or ""

  if modelInput ~= "" then
    local num = tonumber(modelInput)
    if num and models[num] then
      cfg.model = models[num].id
    elseif modelInput:match("^claude%-") then
      cfg.model = modelInput
    else
      print("Invalid selection, keeping current model.")
    end
  end

  -- Max tokens
  io.write("Max tokens [" .. cfg.max_tokens .. "]: ")
  local tokens = term.read()
  tokens = tokens and tokens:gsub("%s+$", "") or ""
  if tokens ~= "" then
    local num = tonumber(tokens)
    if num then cfg.max_tokens = num end
  end

  local success, err = config.save(cfg)
  if success then
    print("")
    print("Configuration saved!")
    print("Run 'claude' to start chatting.")
  else
    print("")
    print("Error saving config: " .. tostring(err))
  end

  return cfg
end

return config
