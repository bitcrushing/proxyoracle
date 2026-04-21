"""
ProxyOracle — Claude API proxy server for OpenComputers clients.

Handles TLS to Anthropic, stores conversation history, filters thinking
blocks, and streams SSE responses to thin OC clients over plain HTTP.

Usage:
    pip install -r requirements.txt
    python proxy.py

First run auto-generates proxy_config.json with a random auth token.
Configure your Anthropic API key in proxy_config.json before use.
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

import anthropic
import requests as http_requests
from flask import Flask, Response, jsonify, request

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "proxy_config.json")

DEFAULT_CONFIG = {
    "api_key": "",
    "auth_token": "",
    "allowed_models": [
        "claude-sonnet-4-6",
        "claude-opus-4-6",
        "claude-haiku-4-5-20251001",
    ],
    "max_sessions": 10,
    "max_messages_per_session": 500,
    "bind_host": "0.0.0.0",
    "bind_port": 8080,
}

# Tool definitions — same schemas as the OC client's tools.lua
TOOL_DEFINITIONS = [
    {
        "name": "Read",
        "description": "Read a file. Use absolute paths.",
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string"},
                "offset": {"type": "number"},
                "limit": {"type": "number"},
            },
            "required": ["file_path"],
        },
    },
    {
        "name": "Write",
        "description": "Write a file. Requires confirmation.",
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string"},
                "content": {"type": "string"},
            },
            "required": ["file_path", "content"],
        },
    },
    {
        "name": "Edit",
        "description": "Find and replace text in a file. Requires confirmation.",
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string"},
                "old_string": {"type": "string"},
                "new_string": {"type": "string"},
                "replace_all": {"type": "boolean"},
            },
            "required": ["file_path", "old_string", "new_string"],
        },
    },
    {
        "name": "Run",
        "description": "Run a shell command. Requires confirmation.",
        "input_schema": {
            "type": "object",
            "properties": {"command": {"type": "string"}},
            "required": ["command"],
        },
    },
    {
        "name": "Glob",
        "description": "Find files by glob pattern (*, **, ?).",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string"},
                "path": {"type": "string"},
            },
            "required": ["pattern"],
        },
    },
    {
        "name": "Grep",
        "description": "Search file contents by Lua pattern.",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string"},
                "path": {"type": "string"},
                "include": {"type": "string"},
            },
            "required": ["pattern"],
        },
    },
    {
        "name": "Fetch",
        "description": "HTTP GET a URL. Returns text content, HTML tags stripped.",
        "input_schema": {
            "type": "object",
            "properties": {"url": {"type": "string"}},
            "required": ["url"],
        },
    },
    {
        "name": "Component",
        "description": "Access OC hardware. action='list' shows components. action='call' invokes a method (address, method, args[]).",
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {"type": "string"},
                "address": {"type": "string"},
                "method": {"type": "string"},
                "args": {"type": "array", "items": {}},
            },
            "required": ["action"],
        },
    },
    {
        "name": "Inventory",
        "description": "Read inventories via transposer/adapter. side=0-5. Optional slot number.",
        "input_schema": {
            "type": "object",
            "properties": {
                "side": {"type": "number"},
                "slot": {"type": "number"},
            },
            "required": ["side"],
        },
    },
    {
        "name": "Redstone",
        "description": "Read/set redstone. action='get' reads input, action='set' sets output (value 0-15).",
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {"type": "string"},
                "side": {"type": "number"},
                "value": {"type": "number"},
            },
            "required": ["action", "side"],
        },
    },
    {
        "name": "ME",
        "description": "AE2/ME system. action='items' (optional filter), action='craft' (item, count), action='status'.",
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {"type": "string"},
                "filter": {"type": "string"},
                "item": {"type": "string"},
                "count": {"type": "number"},
            },
            "required": ["action"],
        },
    },
    {
        "name": "Robot",
        "description": "Control robot. action: move/turn/swing/place/use/detect/inspect/suck/drop/inventory. direction: forward/up/down. side: left/right.",
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {"type": "string"},
                "direction": {"type": "string"},
                "side": {"type": "string"},
                "slot": {"type": "number"},
            },
            "required": ["action"],
        },
    },
    {
        "name": "Scan",
        "description": "Terrain scanning. action='block' (x,y,z offset), action='area' (w,d,h volume), action='position' (GPS coords).",
        "input_schema": {
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
        },
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
    print("Please set your Anthropic API key in proxy_config.json")
    print(f"{'='*60}\n")
    return cfg


def save_config(cfg):
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)


config = load_config()

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

def stream_anthropic_response(session):
    """
    Call Anthropic API with session state, stream SSE events to the OC client.
    Filters out thinking events. Stores assistant response in session.
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

    client = anthropic.Anthropic(api_key=config["api_key"])

    # Build API request
    api_kwargs = {
        "model": session["model"],
        "max_tokens": session["max_tokens"],
        "messages": session["messages"],
        "tools": TOOL_DEFINITIONS,
        "thinking": {"type": "adaptive"},
        "output_config": {"effort": "high"},
    }

    if session["system_prompt"]:
        api_kwargs["system"] = session["system_prompt"]

    # Track content blocks for storage
    content_blocks = {}
    json_accumulator = []
    usage = {"input_tokens": 0, "output_tokens": 0}
    stop_reason = None

    # Track which blocks are thinking (to filter from SSE output)
    thinking_indices = set()

    max_retries = 2
    last_error = None

    for attempt in range(max_retries):
        try:
            with client.messages.stream(
                **api_kwargs,
                extra_headers={
                    "anthropic-beta": "interleaved-thinking-2025-05-14,effort-2025-11-24"
                },
            ) as stream:
                for event in stream:
                    event_type = event.type
                    event_data = event.model_dump()

                    # --- Track content blocks for storage ---

                    if event_type == "content_block_start":
                        idx = event_data.get("index", 0)
                        block = event_data.get("content_block", {})
                        block_type = block.get("type", "")

                        if block_type == "thinking":
                            thinking_indices.add(idx)
                            content_blocks[idx] = {
                                "type": "thinking",
                                "thinking": "",
                                "signature": "",
                            }
                            continue  # Don't forward to OC

                        elif block_type == "text":
                            content_blocks[idx] = {"type": "text", "text": ""}
                        elif block_type == "tool_use":
                            content_blocks[idx] = {
                                "type": "tool_use",
                                "id": block.get("id", ""),
                                "name": block.get("name", ""),
                                "input": {},
                            }
                            json_accumulator.clear()

                    elif event_type == "content_block_delta":
                        idx = event_data.get("index", 0)
                        delta = event_data.get("delta", {})
                        delta_type = delta.get("type", "")

                        if idx in thinking_indices:
                            # Accumulate thinking for storage, don't forward
                            if delta_type == "thinking_delta":
                                content_blocks[idx]["thinking"] += delta.get("thinking", "")
                            elif delta_type == "signature_delta":
                                content_blocks[idx]["signature"] = delta.get("signature", "")
                            continue  # Don't forward to OC

                        if delta_type == "text_delta":
                            text = delta.get("text", "")
                            if idx in content_blocks and content_blocks[idx]["type"] == "text":
                                content_blocks[idx]["text"] += text
                        elif delta_type == "input_json_delta":
                            json_accumulator.append(delta.get("partial_json", ""))

                    elif event_type == "content_block_stop":
                        idx = event_data.get("index", 0)
                        if idx in thinking_indices:
                            continue  # Don't forward

                        # Parse accumulated tool input JSON
                        if idx in content_blocks and content_blocks[idx]["type"] == "tool_use":
                            full_json = "".join(json_accumulator)
                            if full_json:
                                try:
                                    content_blocks[idx]["input"] = json.loads(full_json)
                                except json.JSONDecodeError:
                                    pass
                            json_accumulator.clear()

                    elif event_type == "message_start":
                        msg = event_data.get("message", {})
                        msg_usage = msg.get("usage", {})
                        usage["input_tokens"] = msg_usage.get("input_tokens", 0)

                    elif event_type == "message_delta":
                        delta = event_data.get("delta", {})
                        msg_usage = event_data.get("usage", {})
                        usage["output_tokens"] = msg_usage.get("output_tokens", 0)
                        stop_reason = delta.get("stop_reason")

                    # --- Forward non-thinking events to OC as SSE ---
                    sse_data = json.dumps(event_data, separators=(",", ":"))
                    yield f"event: {event_type}\ndata: {sse_data}\n\n"

            # Stream completed successfully
            last_error = None
            break

        except anthropic.RateLimitError:
            last_error = "Rate limited by Anthropic"
            if attempt < max_retries - 1:
                time.sleep(2)
                continue
        except anthropic.InternalServerError:
            last_error = "Anthropic server error"
            if attempt < max_retries - 1:
                time.sleep(2)
                continue
        except anthropic.APIError as e:
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
    for idx in sorted(content_blocks.keys()):
        ordered_content.append(content_blocks[idx])

    if ordered_content:
        session["messages"].append({"role": "assistant", "content": ordered_content})

    # Update token counters
    session["total_input_tokens"] += usage.get("input_tokens", 0)
    session["total_output_tokens"] += usage.get("output_tokens", 0)


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------

@app.route("/session", methods=["POST"])
@require_auth
def create_session_endpoint():
    if not check_rate_limit():
        return jsonify({"error": {"type": "rate_limit", "message": "Too many requests"}}), 429

    data = request.get_json(silent=True) or {}
    model = data.get("model", "claude-sonnet-4-6")
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
        stream_anthropic_response(session),
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
        stream_anthropic_response(session),
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
        if tag in ("br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"):
            self._parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript", "nav", "footer", "head"):
            self._skip = False
        if tag in ("p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"):
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
        resp = http_requests.get(
            url,
            timeout=FETCH_TIMEOUT,
            headers={
                "User-Agent": "Mozilla/5.0 (compatible; ProxyOracle/1.0)",
                "Accept": "text/html,text/plain,*/*",
                "Accept-Language": "en-US,en;q=0.9",
            },
            stream=True,
            allow_redirects=True,
        )

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
        resp.close()

        raw = b"".join(chunks)
        content_type = resp.headers.get("content-type", "")
        status_code = resp.status_code

        # Decode bytes to text
        encoding = resp.encoding or "utf-8"
        try:
            text = raw.decode(encoding, errors="replace")
        except (LookupError, UnicodeDecodeError):
            text = raw.decode("utf-8", errors="replace")

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
        print(f"Edit {CONFIG_PATH} and set your Anthropic API key.\n")

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
