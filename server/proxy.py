"""
ProxyOracle — Claude API proxy server for OpenComputers clients.

Handles TLS to OpenCode Zen, stores conversation history, filters thinking
blocks, and streams SSE responses to thin OC clients over plain HTTP.

Usage:
    pip install -r requirements.txt
    python proxy.py

First run auto-generates proxy_config.json with a random auth token.
Configure your OpenCode Zen API key in proxy_config.json before use.
"""

import html
import json
import os
import re
import secrets
import time
import uuid
from functools import wraps
from html.parser import HTMLParser

import openai
from openai import OpenAI
import requests as http_requests
from flask import Flask, Response, jsonify, request

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "proxy_config.json")
SESSIONS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sessions")

DEFAULT_CONFIG = {
    "api_key": "",
    "auth_token": "",
    "allowed_models": [
        "big-pickle",
        "claude-haiku-4-5",
        "claude-opus-4-7",
        "claude-sonnet-4-6",
        "gemini-3-flash",
        "gemini-3.1-pro",
        "glm-5.1",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5.5",
        "gpt-5.5-pro",
        "kimi-k2.6",
        "minimax-m2.7",
        "qwen3.6-plus",
        "trinity-large-preview-free"
    ],
    "max_sessions": 10,
    "max_messages_per_session": 500,
    "bind_host": "0.0.0.0",
    "bind_port": 8080,
}

# Tool definitions — same schemas as the OC client's tools.lua

# Tool definitions in OpenAI format
TOOL_DEFINITIONS = [
    {
        "type": "function",
        "function": {
            "name": "Read",
            "description": "Read a file. Use absolute paths.",
            "parameters": {
                "type": "object",
                "properties": {
                    "file_path": {"type": "string"},
                    "offset": {"type": "number"},
                    "limit": {"type": "number"},
                },
                "required": ["file_path"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Write",
            "description": "Write a file. Requires confirmation.",
            "parameters": {
                "type": "object",
                "properties": {
                    "file_path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["file_path", "content"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Edit",
            "description": "Find and replace text in a file. Requires confirmation.",
            "parameters": {
                "type": "object",
                "properties": {
                    "file_path": {"type": "string"},
                    "old_string": {"type": "string"},
                    "new_string": {"type": "string"},
                    "replace_all": {"type": "boolean"},
                },
                "required": ["file_path", "old_string", "new_string"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Run",
            "description": "Run a shell command. Requires confirmation.",
            "parameters": {
                "type": "object",
                "properties": {"command": {"type": "string"}},
                "required": ["command"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Glob",
            "description": "Find files by glob pattern (*, **, ?).",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string"},
                    "path": {"type": "string"},
                },
                "required": ["pattern"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Grep",
            "description": "Search file contents by Lua pattern.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string"},
                    "path": {"type": "string"},
                    "include": {"type": "string"},
                },
                "required": ["pattern"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Fetch",
            "description": "HTTP GET a URL. Returns text content, HTML tags stripped.",
            "parameters": {
                "type": "object",
                "properties": {"url": {"type": "string"}},
                "required": ["url"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Component",
            "description": "Access OC hardware. action='list' shows components. action='call' invokes a method (address, method, args[]).",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string"},
                    "address": {"type": "string"},
                    "method": {"type": "string"},
                    "args": {"type": "array", "items": {}},
                },
                "required": ["action"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Inventory",
            "description": "Read inventories via transposer/adapter. side=0-5. Optional slot number.",
            "parameters": {
                "type": "object",
                "properties": {
                    "side": {"type": "number"},
                    "slot": {"type": "number"},
                },
                "required": ["side"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Redstone",
            "description": "Read/set redstone. action='get' reads input, action='set' sets output (value 0-15).",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string"},
                    "side": {"type": "number"},
                    "value": {"type": "number"},
                },
                "required": ["action", "side"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "ME",
            "description": "AE2/ME system. action='items' (optional filter), action='craft' (item, count), action='status'.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string"},
                    "filter": {"type": "string"},
                    "item": {"type": "string"},
                    "count": {"type": "number"},
                },
                "required": ["action"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Robot",
            "description": "Control robot. action: move/turn/swing/place/use/detect/inspect/suck/drop/inventory. direction: forward/up/down. side: left/right.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string"},
                    "direction": {"type": "string"},
                    "side": {"type": "string"},
                    "slot": {"type": "number"},
                },
                "required": ["action"],
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Scan",
            "description": "Terrain scanning. action='block' (x,y,z offset), action='area' (w,d,h volume), action='position' (GPS coords).",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string"},
                    "x": {"type": "number"},
                    "y": {"type": "number"},
                    "z": {"type": "number"},
                    "w": {"type": "number"},
                    "d": {"type": "number"},
                    "h": {"type": "number"},
                },
                "required": ["action"],
            }
        }
    },
]


def load_config():
    """Load or create proxy configuration."""
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
        # Merge with defaults for any missing keys
        for k, v in DEFAULT_CONFIG.items():
            if k not in cfg:
                cfg[k] = v
        return cfg

    # First run: generate auth token
    cfg = dict(DEFAULT_CONFIG)
    cfg["auth_token"] = secrets.token_hex(32)
    save_config(cfg)
    print(f"\n{'='*60}")
    print("First run — generated proxy_config.json")
    print(f"Auth token: {cfg['auth_token']}")
    print("Please set your OpenCode Zen API key in proxy_config.json")
    print(f"{'='*60}\n")
    return cfg


def save_config(cfg):
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)


def save_session(session):
    """Persist a session to disk so it survives proxy restarts."""
    try:
        os.makedirs(SESSIONS_DIR, exist_ok=True)
        session["last_updated"] = time.time()
        path = os.path.join(SESSIONS_DIR, session["id"] + ".json")
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(session, f, separators=(",", ":"))
        os.replace(tmp, path)
    except Exception:
        pass  # Non-critical — session still works in memory


def load_sessions():
    """Load persisted sessions from disk on startup."""
    if not os.path.exists(SESSIONS_DIR):
        return
    for fname in os.listdir(SESSIONS_DIR):
        if not fname.endswith(".json"):
            continue
        path = os.path.join(SESSIONS_DIR, fname)
        try:
            with open(path) as f:
                session = json.load(f)
            required = ("id", "model", "max_tokens", "messages", "created_at")
            if all(k in session for k in required):
                sessions[session["id"]] = session
        except Exception:
            pass  # Skip corrupt files


config = load_config()
load_sessions()

# ---------------------------------------------------------------------------
# Session storage
# ---------------------------------------------------------------------------

sessions = {}


def create_session(model, max_tokens, system_prompt):
    if len(sessions) >= config["max_sessions"]:
        # Evict oldest session
        oldest_id = min(sessions, key=lambda k: sessions[k]["created_at"])
        del sessions[oldest_id]

    session_id = uuid.uuid4().hex[:12]
    sessions[session_id] = {
        "id": session_id,
        "model": model,
        "max_tokens": max_tokens,
        "system_prompt": system_prompt,
        "messages": [],
        "total_input_tokens": 0,
        "total_output_tokens": 0,
        "created_at": time.time(),
    }
    return session_id


def get_session(session_id):
    return sessions.get(session_id)


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return jsonify({"error": {"type": "auth_error", "message": "Missing Bearer token"}}), 401
        token = auth[7:]
        if token != config["auth_token"]:
            return jsonify({"error": {"type": "auth_error", "message": "Invalid token"}}), 401
        return f(*args, **kwargs)
    return decorated


# ---------------------------------------------------------------------------
# Rate limiting (simple in-memory)
# ---------------------------------------------------------------------------

rate_limit_state = {}
RATE_LIMIT_WINDOW = 60  # seconds
RATE_LIMIT_MAX = 30  # requests per window


def check_rate_limit():
    now = time.time()
    # Clean old entries
    cutoff = now - RATE_LIMIT_WINDOW
    rate_limit_state["times"] = [t for t in rate_limit_state.get("times", []) if t > cutoff]
    if len(rate_limit_state.get("times", [])) >= RATE_LIMIT_MAX:
        return False
    rate_limit_state.setdefault("times", []).append(now)
    return True


# ---------------------------------------------------------------------------
# SSE streaming helpers
# ---------------------------------------------------------------------------

def stream_opencode_response(session):
    """
    Call OpenCode Zen API with session state, stream SSE events to the OC client.
    Converts OpenAI streaming chunks back to the format the Lua client expects.
    """
    if not config["api_key"]:
        yield 'event: error\ndata: {"error":{"type":"config_error","message":"API key not configured on proxy"}}\n\n'
        return

    # Validate model
    if session["model"] not in config["allowed_models"]:
        yield f'event: error\ndata: {{"error":{{"type":"config_error","message":"Model not allowed: {session["model"]}"}}}}\n\n'
        return

    # Check message limit
    if len(session["messages"]) >= config["max_messages_per_session"]:
        yield 'event: error\ndata: {"error":{"type":"limit_error","message":"Session message limit reached. Use /clear to start fresh."}}\n\n'
        return

    client = OpenAI(api_key=config["api_key"], base_url="https://opencode.ai/zen/v1")

    # Translate messages to OpenAI format
    openai_messages = []
    if session["system_prompt"]:
        openai_messages.append({"role": "system", "content": session["system_prompt"]})
        
    for msg in session["messages"]:
        if msg["role"] == "user":
            if isinstance(msg["content"], str):
                openai_messages.append({"role": "user", "content": msg["content"]})
            else:
                # User sending tool_result
                for block in msg["content"]:
                    if block.get("type") == "tool_result":
                        openai_messages.append({
                            "role": "tool",
                            "tool_call_id": block.get("tool_use_id", ""),
                            "content": str(block.get("content", ""))
                        })
        elif msg["role"] == "assistant":
            # Translate content array to string + tool_calls
            text_content = ""
            tool_calls = []
            for block in msg["content"]:
                if block["type"] == "text":
                    text_content += block.get("text", "")
                elif block["type"] == "tool_use":
                    tool_input = block.get("input", {})
                    if not isinstance(tool_input, dict):
                        tool_input = {}
                    tool_calls.append({
                        "id": block.get("id", ""),
                        "type": "function",
                        "function": {
                            "name": block.get("name", ""),
                            "arguments": json.dumps(tool_input)
                        }
                    })
            msg_dict = {"role": "assistant"}
            if tool_calls:
                msg_dict["tool_calls"] = tool_calls
                # OpenAI requires content to be null (not "") when tool_calls are present
                msg_dict["content"] = text_content if text_content else None
            else:
                msg_dict["content"] = text_content
            openai_messages.append(msg_dict)

    api_kwargs = {
        "model": session["model"],
        "messages": openai_messages,
        "tools": TOOL_DEFINITIONS,
        "stream": True,
        "stream_options": {"include_usage": True}
    }

    # Tracking for storage and Anthropic-format emission
    content_blocks = {}
    
    max_retries = 2
    last_error = None

    for attempt in range(max_retries):
        try:
            response = client.chat.completions.create(**api_kwargs)
            
            # Emit message_start
            yield f'event: message_start\ndata: {{"type":"message_start","message":{{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"{session["model"]}","stop_reason":null,"stop_sequence":null,"usage":{{"input_tokens":0,"output_tokens":0}}}}}}\n\n'
            
            idx = 0
            current_block_type = None
            final_stop_reason = "end_turn"
            final_in_t = 0
            final_out_t = 0
            tool_call_map = {}  # Maps OpenAI tool_call.index -> content_block index
            
            for chunk in response:
                if chunk.choices and len(chunk.choices) > 0:
                    delta = chunk.choices[0].delta
                    if chunk.choices[0].finish_reason:
                        fr = chunk.choices[0].finish_reason
                        if fr == "tool_calls":
                            final_stop_reason = "tool_use"
                        elif fr == "length":
                            final_stop_reason = "max_tokens"
                        elif fr == "stop":
                            final_stop_reason = "end_turn"
                    
                    if delta.content:
                        if current_block_type != "text":
                            if current_block_type is not None:
                                yield f'event: content_block_stop\ndata: {{"type":"content_block_stop","index":{idx}}}\n\n'
                                idx += 1
                            current_block_type = "text"
                            content_blocks[idx] = {"type": "text", "text": ""}
                            yield f'event: content_block_start\ndata: {{"type":"content_block_start","index":{idx},"content_block":{{"type":"text","text":""}}}}\n\n'
                        
                        content_blocks[idx]["text"] += delta.content
                        safe_content = json.dumps(delta.content)
                        yield f'event: content_block_delta\ndata: {{"type":"content_block_delta","index":{idx},"delta":{{"type":"text_delta","text":{safe_content}}}}}\n\n'

                    if delta.tool_calls:
                        for tool_call in delta.tool_calls:
                            tc_idx = tool_call.index
                            
                            if tc_idx not in tool_call_map:
                                # New tool call — require both id and name
                                tc_name = getattr(getattr(tool_call, "function", None), "name", None)
                                tc_id = getattr(tool_call, "id", None)
                                if not tc_name or not tc_id:
                                    # Skip incomplete tool call init
                                    continue
                                
                                if current_block_type is not None:
                                    yield f'event: content_block_stop\ndata: {{"type":"content_block_stop","index":{idx}}}\n\n'
                                    idx += 1
                                current_block_type = "tool_use"
                                tool_call_map[tc_idx] = idx
                                content_blocks[idx] = {"type": "tool_use", "id": tc_id, "name": tc_name, "input": {}}
                                yield f'event: content_block_start\ndata: {{"type":"content_block_start","index":{idx},"content_block":{{"type":"tool_use","id":"{tc_id}","name":"{tc_name}","input":{{}}}}}}\n\n'
                            
                            block_idx = tool_call_map.get(tc_idx)
                            if block_idx is not None:
                                args = getattr(getattr(tool_call, "function", None), "arguments", None)
                                if args:
                                    if "raw_json" not in content_blocks[block_idx]:
                                        content_blocks[block_idx]["raw_json"] = ""
                                    content_blocks[block_idx]["raw_json"] += args
                                    safe_args = json.dumps(args)
                                    yield f'event: content_block_delta\ndata: {{"type":"content_block_delta","index":{block_idx},"delta":{{"type":"input_json_delta","partial_json":{safe_args}}}}}\n\n'

                if getattr(chunk, "usage", None):
                    # Final usage
                    # parse final tool json inputs for storage
                    for b_idx, block in content_blocks.items():
                        if block["type"] == "tool_use" and "raw_json" in block:
                            try:
                                block["input"] = json.loads(block["raw_json"])
                            except:
                                pass
                            del block["raw_json"]
                            
                    # Update token counters
                    final_in_t = chunk.usage.prompt_tokens
                    final_out_t = chunk.usage.completion_tokens
                    session["total_input_tokens"] += final_in_t
                    session["total_output_tokens"] += final_out_t
            
            # Safety: parse any remaining raw_json before storing
            for b_idx, block in content_blocks.items():
                if block["type"] == "tool_use" and "raw_json" in block:
                    try:
                        block["input"] = json.loads(block["raw_json"])
                    except:
                        pass
                    del block["raw_json"]
                    
            if current_block_type is not None:
                yield f'event: content_block_stop\ndata: {{"type":"content_block_stop","index":{idx}}}\n\n'
                
            yield f'event: message_delta\ndata: {{"type":"message_delta","delta":{{"stop_reason":"{final_stop_reason}","stop_sequence":null}},"usage":{{"input_tokens":{final_in_t},"output_tokens":{final_out_t}}}}}\n\n'
            yield f'event: message_stop\ndata: {{"type":"message_stop"}}\n\n'

            # Stream completed successfully
            last_error = None
            break

        except openai.RateLimitError:
            last_error = "Rate limited by OpenCode Zen"
            if attempt < max_retries - 1:
                import time
                time.sleep(2)
                continue
        except openai.InternalServerError:
            last_error = "OpenCode Zen server error"
            if attempt < max_retries - 1:
                import time
                time.sleep(2)
                continue
        except openai.APIError as e:
            last_error = str(e)
            yield f'event: error\ndata: {{"error":{{"type":"api_error","message":{json.dumps(last_error)}}}}}\n\n'
            return
        except Exception as e:
            last_error = str(e)
            yield f'event: error\ndata: {{"error":{{"type":"proxy_error","message":{json.dumps(last_error)}}}}}\n\n'
            return

    if last_error:
        yield f'event: error\ndata: {{"error":{{"type":"api_error","message":{json.dumps(last_error)}}}}}\n\n'
        return

    # Store assistant response in session
    ordered_content = []
    for i in sorted(content_blocks.keys()):
        ordered_content.append(content_blocks[i])

    if ordered_content:
        session["messages"].append({"role": "assistant", "content": ordered_content})

    save_session(session)


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------

@app.route("/session", methods=["POST"])
@require_auth
def create_session_endpoint():
    if not check_rate_limit():
        return jsonify({"error": {"type": "rate_limit", "message": "Too many requests"}}), 429

    data = request.get_json(silent=True) or {}
    model = data.get("model", "gpt-5.5")
    max_tokens = data.get("max_tokens", 16384)
    system_prompt = data.get("system_prompt", "")

    if model not in config["allowed_models"]:
        return jsonify({"error": {"type": "config_error", "message": f"Model not allowed: {model}"}}), 400

    session_id = create_session(model, max_tokens, system_prompt)
    return jsonify({"session_id": session_id})


@app.route("/session/<session_id>/message", methods=["POST"])
@require_auth
def send_message(session_id):
    if not check_rate_limit():
        return jsonify({"error": {"type": "rate_limit", "message": "Too many requests"}}), 429

    session = get_session(session_id)
    if not session:
        return jsonify({"error": {"type": "not_found", "message": "Session not found"}}), 404

    data = request.get_json(silent=True) or {}
    text = data.get("text", "")
    if not text:
        return jsonify({"error": {"type": "invalid_request", "message": "Missing text"}}), 400

    # Add user message to session
    session["messages"].append({"role": "user", "content": text})

    return Response(
        stream_opencode_response(session),
        content_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.route("/session/<session_id>/tool_result", methods=["POST"])
@require_auth
def send_tool_result(session_id):
    if not check_rate_limit():
        return jsonify({"error": {"type": "rate_limit", "message": "Too many requests"}}), 429

    session = get_session(session_id)
    if not session:
        return jsonify({"error": {"type": "not_found", "message": "Session not found"}}), 404

    data = request.get_json(silent=True) or {}
    results = data.get("results", [])
    if not results:
        return jsonify({"error": {"type": "invalid_request", "message": "Missing results"}}), 400

    # Build tool_result content blocks
    content = []
    for r in results:
        is_error = r.get("is_error", False)
        # OC client may send is_error as string "true"/"false" due to json.lua limitations
        if isinstance(is_error, str):
            is_error = is_error.lower() == "true"
        content.append({
            "type": "tool_result",
            "tool_use_id": r.get("tool_use_id", ""),
            "content": r.get("content", ""),
            "is_error": is_error,
        })

    session["messages"].append({"role": "user", "content": content})

    return Response(
        stream_opencode_response(session),
        content_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.route("/session/<session_id>/status", methods=["GET"])
@require_auth
def session_status(session_id):
    session = get_session(session_id)
    if not session:
        return jsonify({"error": {"type": "not_found", "message": "Session not found"}}), 404

    return jsonify({
        "session_id": session["id"],
        "message_count": len(session["messages"]),
        "total_input_tokens": session["total_input_tokens"],
        "total_output_tokens": session["total_output_tokens"],
        "model": session["model"],
        "created_at": session["created_at"],
    })


@app.route("/session/<session_id>/history", methods=["GET"])
@require_auth
def session_history(session_id):
    session = get_session(session_id)
    if not session:
        return jsonify({"error": {"type": "not_found", "message": "Session not found"}}), 404

    # Return condensed history: role + text preview for each message
    history = []
    for msg in session["messages"]:
        role = msg.get("role", "?")
        content = msg.get("content", "")
        preview = ""

        if isinstance(content, str):
            preview = content[:80]
        elif isinstance(content, list):
            parts = []
            for block in content:
                if isinstance(block, dict):
                    if block.get("type") == "text":
                        parts.append(block.get("text", "")[:80])
                    elif block.get("type") == "tool_use":
                        parts.append("[" + block.get("name", "tool") + "]")
                    elif block.get("type") == "tool_result":
                        parts.append("[result]")
            preview = " ".join(parts)[:80]

        history.append({"role": role, "preview": preview})

    return jsonify({"history": history, "count": len(history)})


@app.route("/session/<session_id>", methods=["DELETE"])
@require_auth
def delete_session(session_id):
    if session_id in sessions:
        del sessions[session_id]
    path = os.path.join(SESSIONS_DIR, session_id + ".json")
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# Server-side fetch endpoint
# ---------------------------------------------------------------------------

class _TextExtractor(HTMLParser):
    """Minimal HTML-to-text: strips tags, decodes entities, collapses whitespace."""
    def __init__(self):
        super().__init__()
        self._parts = []
        self._skip = False

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "noscript", "nav", "footer", "head"):
            self._skip = True
        elif not self._skip and tag in ("br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"):
            self._parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript", "nav", "footer", "head"):
            self._skip = False
        elif not self._skip and tag in ("p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"):
            self._parts.append("\n")

    def handle_data(self, data):
        if not self._skip:
            self._parts.append(data)

    def get_text(self):
        text = "".join(self._parts)
        text = re.sub(r"[ \t]+", " ", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()


FETCH_MAX_BYTES = 8192        # cap returned to OC client
FETCH_DOWNLOAD_MAX = 2 * 1024 * 1024  # 2MB download cap before stripping
FETCH_TIMEOUT = 20            # seconds


@app.route("/fetch", methods=["POST"])
@require_auth
def proxy_fetch():
    """Fetch a URL server-side and return stripped text to the OC client."""
    if not check_rate_limit():
        return jsonify({"error": "Too many requests"}), 429

    data = request.get_json(silent=True) or {}
    url = data.get("url", "").strip()
    if not url:
        return jsonify({"error": "Missing url"}), 400

    # Require http/https scheme
    if not url.lower().startswith(("http://", "https://")):
        return jsonify({"error": "Only http/https URLs are supported"}), 400

    try:
        with http_requests.get(
            url,
            timeout=FETCH_TIMEOUT,
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
                "Accept": "text/html,text/plain,*/*",
                "Accept-Language": "en-US,en;q=0.9",
            },
            stream=True,
            allow_redirects=True,
        ) as resp:
            # Read up to FETCH_DOWNLOAD_MAX bytes
            chunks = []
            total = 0
            truncated = False
            for chunk in resp.iter_content(chunk_size=4096):
                if chunk:
                    total += len(chunk)
                    if total <= FETCH_DOWNLOAD_MAX:
                        chunks.append(chunk)
                    else:
                        truncated = True
                        break

            raw = b"".join(chunks)
            content_type = resp.headers.get("content-type", "")
            status_code = resp.status_code
            encoding = resp.encoding or "utf-8"

        # Decode bytes to text (outside `with` — connection already closed)
        try:
            text = raw.decode(encoding, errors="replace")
        except (LookupError, UnicodeDecodeError):
            text = raw.decode("utf-8", errors="replace")

        # Sanitize: remove surrogate characters that break JSON UTF-8 encoding
        text = text.encode("utf-8", "surrogatepass").decode("utf-8", "ignore")

        # Strip HTML if applicable
        if "html" in content_type.lower():
            extractor = _TextExtractor()
            try:
                extractor.feed(text)
                text = extractor.get_text()
            except Exception:
                # Fall back to simple regex strip
                text = re.sub(r"<[^>]+>", " ", text)
                text = html.unescape(text)
                text = re.sub(r"\s+", " ", text).strip()
        else:
            text = html.unescape(text)

        # Truncate to FETCH_MAX_BYTES for OC client
        if len(text) > FETCH_MAX_BYTES:
            text = text[:FETCH_MAX_BYTES]
            truncated = True

        if truncated:
            text += f"\n\n(Truncated — fetched {total} bytes total)"

        return jsonify({
            "content": text,
            "status_code": status_code,
            "url": resp.url,
            "truncated": truncated,
        })

    except http_requests.exceptions.Timeout:
        return jsonify({"error": f"Request timed out after {FETCH_TIMEOUT}s"}), 200
    except http_requests.exceptions.TooManyRedirects:
        return jsonify({"error": "Too many redirects"}), 200
    except http_requests.exceptions.ConnectionError as e:
        return jsonify({"error": f"Connection error: {e}"}), 200
    except Exception as e:
        return jsonify({"error": f"Fetch failed: {e}"}), 200


@app.route("/sessions", methods=["GET"])
@require_auth
def list_sessions_endpoint():
    result = []
    for session in sessions.values():
        # Find the most recent user text message for the preview
        last_msg = ""
        for msg in reversed(session["messages"]):
            content = msg.get("content", "")
            if isinstance(content, str) and msg.get("role") == "user":
                last_msg = content[:60]
                break
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        text = block.get("text", "").strip()
                        if text:
                            last_msg = text[:60]
                            break
                if last_msg:
                    break

        ts = session.get("last_updated", session["created_at"])
        result.append({
            "id": session["id"],
            "model": session["model"],
            "message_count": len(session["messages"]),
            "ts": ts,
            "last_updated": time.strftime("%b %d %H:%M", time.localtime(ts)),
            "last_message": last_msg,
        })

    result.sort(key=lambda s: s["ts"], reverse=True)
    for s in result:
        del s["ts"]

    return jsonify({"sessions": result})


@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "ok",
        "sessions": len(sessions),
        "api_key_configured": bool(config["api_key"]),
    })


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    if not config["api_key"]:
        print("\nWARNING: No API key configured!")
        print(f"Edit {CONFIG_PATH} and set your OpenCode Zen API key.\n")

    print(f"ProxyOracle starting on {config['bind_host']}:{config['bind_port']}")
    print(f"Auth token: {config['auth_token'][:8]}...")
    print(f"Allowed models: {', '.join(config['allowed_models'])}")
    print(f"Max sessions: {config['max_sessions']}")
    print()

    app.run(
        host=config["bind_host"],
        port=config["bind_port"],
        threaded=True,
    )
