-- JSON library for OpenComputers
-- Handles encoding/decoding JSON for Claude API communication
-- Optimized for minimal memory allocation

local json = {}

-- Module-level escape map (avoids re-creation per gsub call)
local JSON_ESCAPE_MAP = {
  ['\\'] = '\\\\',
  ['"'] = '\\"',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t'
}

-- Encode a Lua value to JSON string
function json.encode(value)
  local t = type(value)

  if value == nil then
    return "null"
  elseif t == "boolean" then
    return value and "true" or "false"
  elseif t == "number" then
    if value ~= value then -- NaN
      return "null"
    elseif value == math.huge then
      return "1e308"
    elseif value == -math.huge then
      return "-1e308"
    else
      return tostring(value)
    end
  elseif t == "string" then
    -- Single pass: escape special chars and control characters
    local escaped = value:gsub('[\x00-\x1f\\"]', function(c)
      return JSON_ESCAPE_MAP[c] or string.format('\\u%04x', string.byte(c))
    end)
    return '"' .. escaped .. '"'
  elseif t == "table" then
    -- Check if it's an array or object
    local isArray = true
    local maxIndex = 0
    local count = 0

    for k, _ in pairs(value) do
      count = count + 1
      if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
        isArray = false
        break
      end
      if k > maxIndex then
        maxIndex = k
      end
    end

    if isArray and maxIndex == count then
      -- Encode as array
      local parts = {}
      for i = 1, #value do
        parts[i] = json.encode(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      -- Encode as object
      local parts = {}
      for k, v in pairs(value) do
        if type(k) == "string" then
          table.insert(parts, json.encode(k) .. ":" .. json.encode(v))
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  else
    error("Cannot encode type: " .. t)
  end
end

-- Byte constants for decoder (avoids string allocations in comparisons)
local B_TAB       = 9    -- \t
local B_LF        = 10   -- \n
local B_CR        = 13   -- \r
local B_SPACE     = 32
local B_QUOTE     = 34   -- "
local B_PLUS      = 43   -- +
local B_COMMA     = 44   -- ,
local B_MINUS     = 45   -- -
local B_DOT       = 46   -- .
local B_0         = 48
local B_9         = 57
local B_COLON     = 58   -- :
local B_E_UPPER   = 69   -- E
local B_E_LOWER   = 101  -- e
local B_LBRACKET  = 91   -- [
local B_BACKSLASH = 92   -- \
local B_RBRACKET  = 93   -- ]
local B_b         = 98
local B_f         = 102
local B_n         = 110
local B_r         = 114
local B_t         = 116
local B_u         = 117
local B_LBRACE    = 123  -- {
local B_RBRACE    = 125  -- }

-- Decode a JSON string to Lua value
function json.decode(str)
  local pos = 1
  local len = #str

  local function skipWhitespace()
    while pos <= len do
      local b = str:byte(pos)
      if b == B_SPACE or b == B_TAB or b == B_LF or b == B_CR then
        pos = pos + 1
      else
        break
      end
    end
  end

  local function parseValue()
    skipWhitespace()
    local b = str:byte(pos)

    if b == B_QUOTE then
      return parseString()
    elseif b == B_LBRACE then
      return parseObject()
    elseif b == B_LBRACKET then
      return parseArray()
    elseif b == B_t then
      if str:sub(pos, pos + 3) == "true" then
        pos = pos + 4
        return true
      end
    elseif b == B_f then
      if str:sub(pos, pos + 4) == "false" then
        pos = pos + 5
        return false
      end
    elseif b == B_n then
      if str:sub(pos, pos + 3) == "null" then
        pos = pos + 4
        return nil
      end
    elseif b == B_MINUS or (b >= B_0 and b <= B_9) then
      return parseNumber()
    end

    error("Invalid JSON at position " .. pos)
  end

  function parseString()
    pos = pos + 1 -- skip opening quote
    local result = {}

    while pos <= len do
      local b = str:byte(pos)

      if b == B_QUOTE then
        pos = pos + 1
        return table.concat(result)
      elseif b == B_BACKSLASH then
        pos = pos + 1
        local esc = str:byte(pos)
        if esc == B_QUOTE then
          table.insert(result, '"')
        elseif esc == B_BACKSLASH then
          table.insert(result, '\\')
        elseif esc == 47 then -- /
          table.insert(result, '/')
        elseif esc == B_b then
          table.insert(result, '\b')
        elseif esc == B_f then
          table.insert(result, '\f')
        elseif esc == B_n then
          table.insert(result, '\n')
        elseif esc == B_r then
          table.insert(result, '\r')
        elseif esc == B_t then
          table.insert(result, '\t')
        elseif esc == B_u then
          local hex = str:sub(pos + 1, pos + 4)
          local codepoint = tonumber(hex, 16)
          if codepoint then
            if codepoint < 128 then
              table.insert(result, string.char(codepoint))
            elseif codepoint < 2048 then
              table.insert(result, string.char(
                192 + math.floor(codepoint / 64),
                128 + (codepoint % 64)
              ))
            else
              table.insert(result, string.char(
                224 + math.floor(codepoint / 4096),
                128 + math.floor((codepoint % 4096) / 64),
                128 + (codepoint % 64)
              ))
            end
          end
          pos = pos + 4
        end
        pos = pos + 1
      else
        table.insert(result, string.char(b))
        pos = pos + 1
      end
    end

    error("Unterminated string")
  end

  function parseNumber()
    local startPos = pos

    -- Handle negative
    if str:byte(pos) == B_MINUS then
      pos = pos + 1
    end

    -- Integer part
    while pos <= len do
      local b = str:byte(pos)
      if b >= B_0 and b <= B_9 then pos = pos + 1 else break end
    end

    -- Decimal part
    if pos <= len and str:byte(pos) == B_DOT then
      pos = pos + 1
      while pos <= len do
        local b = str:byte(pos)
        if b >= B_0 and b <= B_9 then pos = pos + 1 else break end
      end
    end

    -- Exponent
    if pos <= len then
      local b = str:byte(pos)
      if b == B_E_LOWER or b == B_E_UPPER then
        pos = pos + 1
        if pos <= len then
          b = str:byte(pos)
          if b == B_PLUS or b == B_MINUS then
            pos = pos + 1
          end
        end
        while pos <= len do
          b = str:byte(pos)
          if b >= B_0 and b <= B_9 then pos = pos + 1 else break end
        end
      end
    end

    return tonumber(str:sub(startPos, pos - 1))
  end

  function parseArray()
    pos = pos + 1 -- skip [
    local result = {}

    skipWhitespace()
    if pos <= len and str:byte(pos) == B_RBRACKET then
      pos = pos + 1
      return result
    end

    while true do
      table.insert(result, parseValue())
      skipWhitespace()

      local b = str:byte(pos)
      if b == B_RBRACKET then
        pos = pos + 1
        return result
      elseif b == B_COMMA then
        pos = pos + 1
      else
        error("Expected ',' or ']' in array")
      end
    end
  end

  function parseObject()
    pos = pos + 1 -- skip {
    local result = {}

    skipWhitespace()
    if pos <= len and str:byte(pos) == B_RBRACE then
      pos = pos + 1
      return result
    end

    while true do
      skipWhitespace()
      if str:byte(pos) ~= B_QUOTE then
        error("Expected string key in object")
      end

      local key = parseString()
      skipWhitespace()

      if str:byte(pos) ~= B_COLON then
        error("Expected ':' after object key")
      end
      pos = pos + 1

      result[key] = parseValue()
      skipWhitespace()

      local b = str:byte(pos)
      if b == B_RBRACE then
        pos = pos + 1
        return result
      elseif b == B_COMMA then
        pos = pos + 1
      else
        error("Expected ',' or '}' in object")
      end
    end
  end

  local result = parseValue()
  skipWhitespace()

  return result
end

return json
