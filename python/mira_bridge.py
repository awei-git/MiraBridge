"""MiraBridge — file-based iPhone <-> Mac messaging over iCloud Drive.

A zero-infrastructure communication layer between a local agent (Python)
and a mobile app (SwiftUI) using iCloud Drive as the message bus.

Protocol:
    heartbeat.json    — agent liveness signal
    users/{id}/
        manifest.json — index of all items + generation counter
        items/        — one JSON file per item (agent-owned)
        commands/     — user -> agent commands (iOS writes, agent reads+deletes)
        archive/      — old items moved here
        todos.json    — todo list
        command_ledger.json — reliable delivery tracking

Item types: request, discussion, feed
Statuses: queued, working, needs-input, done, failed, archived
"""
import json
import logging
import subprocess
import time
import uuid
from datetime import datetime, timezone, timedelta
from pathlib import Path

__version__ = "0.1.0"

log = logging.getLogger("mira_bridge")


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def _utc_iso() -> str:
    """UTC timestamp in iOS-compatible ISO8601 format with milliseconds."""
    now = datetime.now(timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"


def _msg_id() -> str:
    return uuid.uuid4().hex[:8]


def _normalize_sender(sender: str) -> str:
    """Normalize sender to 'user' or 'agent'."""
    if sender in ("iphone", "user"):
        return "user"
    return sender  # "agent" stays as-is


def _atomic_write(path: Path, data):
    """Write JSON atomically via tmp+rename."""
    tmp = path.with_suffix(".tmp")
    content = json.dumps(data, indent=2, ensure_ascii=False) if isinstance(data, (dict, list)) else data
    tmp.write_text(content, encoding="utf-8")
    tmp.rename(path)


def _ensure_downloaded(path: Path):
    """Force iCloud Drive to download a file if it's a cloud placeholder (macOS only)."""
    try:
        subprocess.run(["brctl", "download", str(path)],
                       capture_output=True, timeout=10)
        for _ in range(5):
            try:
                path.read_bytes()
                return
            except OSError:
                time.sleep(0.5)
    except FileNotFoundError:
        pass  # brctl not available (Linux, etc.)
    except Exception as e:
        log.warning("brctl download failed for %s: %s", path.name, e)


# ---------------------------------------------------------------------------
# Bridge
# ---------------------------------------------------------------------------

class Bridge:
    """File-based message queue over iCloud Drive — multi-user item protocol.

    Each user has their own namespace: users/{user_id}/items/, commands/, etc.
    Shared items live in shared/items/.

    Usage:
        bridge = Bridge("/path/to/icloud/MyApp-Bridge", user_id="default")
        bridge.heartbeat()
        commands = bridge.poll_commands()
        bridge.create_item("task_001", "request", "Hello", "Do something")
        bridge.update_status("task_001", "done", agent_message="All done!")
    """

    def __init__(self, bridge_dir: str | Path, user_id: str = "default"):
        self.bridge_dir = Path(bridge_dir)
        self.user_id = user_id

        # Per-user paths
        self.user_dir = self.bridge_dir / "users" / user_id
        self.items_dir = self.user_dir / "items"
        self.commands_dir = self.user_dir / "commands"
        self.archive_dir = self.user_dir / "archive"
        self.manifest_file = self.user_dir / "manifest.json"
        self.user_config_file = self.user_dir / "config.json"
        self.ledger_file = self.user_dir / "command_ledger.json"

        # Global paths
        self.heartbeat_file = self.bridge_dir / "heartbeat.json"
        self.profiles_file = self.bridge_dir / "profiles.json"

        # Ensure directories exist
        for d in [self.items_dir, self.commands_dir, self.archive_dir]:
            d.mkdir(parents=True, exist_ok=True)

        # Load user config
        self._user_config = self._load_user_config()

    @property
    def agent_name(self) -> str:
        return self._user_config.get("agent_name", "Agent")

    def _load_user_config(self) -> dict:
        if self.user_config_file.exists():
            try:
                return json.loads(self.user_config_file.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                pass
        return {"agent_name": "Agent", "display_name": self.user_id}

    @classmethod
    def for_all_users(cls, bridge_dir: str | Path) -> list["Bridge"]:
        """Create Bridge instances for all registered users."""
        bridge_dir = Path(bridge_dir)
        users_dir = bridge_dir / "users"
        if not users_dir.exists():
            return [cls(bridge_dir)]
        instances = []
        for user_dir in sorted(users_dir.iterdir()):
            if user_dir.is_dir() and not user_dir.name.startswith("."):
                instances.append(cls(bridge_dir, user_id=user_dir.name))
        return instances or [cls(bridge_dir)]

    # ==================================================================
    # Item CRUD — agent-owned, atomic writes
    # ==================================================================

    def create_item(self, item_id: str, item_type: str, title: str,
                    first_message: str, sender: str = "user",
                    tags: list[str] | None = None,
                    origin: str = "user",
                    quick: bool = False,
                    parent_id: str = "") -> dict:
        """Create a new item (request, discussion, or feed)."""
        sender = _normalize_sender(sender)
        now = _utc_iso()
        item = {
            "id": item_id,
            "type": item_type,
            "title": title,
            "status": "queued",
            "tags": tags or [],
            "origin": origin,
            "pinned": False,
            "quick": quick,
            "parent_id": parent_id,
            "created_at": now,
            "updated_at": now,
            "messages": [
                {"id": _msg_id(), "sender": sender,
                 "content": first_message, "timestamp": now, "kind": "text"},
            ],
            "error": None,
            "result_path": None,
        }
        self._write_item(item)
        self._update_manifest(item)
        return item

    def create_feed(self, feed_id: str, title: str, content: str,
                    tags: list[str] | None = None) -> dict:
        """Create a feed item (briefing, journal, notification). Auto-completed."""
        item = self.create_item(feed_id, "feed", title, content,
                                sender="agent", tags=tags, origin="agent")
        item["status"] = "done"
        self._write_item(item)
        self._update_manifest(item)
        return item

    def create_discussion(self, disc_id: str, title: str, first_message: str,
                          sender: str = "agent", tags: list[str] | None = None,
                          parent_id: str = "") -> dict:
        """Create a discussion (agent-initiated conversation)."""
        item = self.create_item(disc_id, "discussion", title, first_message,
                                sender=sender, tags=tags,
                                origin="agent" if sender == "agent" else "user",
                                parent_id=parent_id)
        if sender == "agent":
            item["status"] = "needs-input"
        self._write_item(item)
        self._update_manifest(item)
        return item

    # --- Item updates ---

    def append_message(self, item_id: str, sender: str, content: str,
                       kind: str = "text") -> dict | None:
        """Append a message to an item. Returns updated item or None."""
        sender = _normalize_sender(sender)
        item = self._read_item(item_id)
        if not item:
            log.warning("append_message: item %s not found", item_id)
            return None

        # Dedup: skip if last message from same sender has identical content
        recent_same = [m for m in item["messages"][-5:] if m["sender"] == sender]
        if recent_same and recent_same[-1]["content"] == content and kind == "text":
            return item

        item["messages"].append({
            "id": _msg_id(), "sender": sender,
            "content": content, "timestamp": _utc_iso(), "kind": kind,
        })
        item["updated_at"] = _utc_iso()
        # Reopen if user replies to done/failed
        if sender != "agent" and item["status"] in ("done", "failed"):
            item["status"] = "queued"
        self._write_item(item)
        self._update_manifest(item)
        return item

    def update_status(self, item_id: str, status: str,
                      agent_message: str = "",
                      result_path: str = "",
                      error: dict | None = None):
        """Update item status with optional message and error."""
        item = self._read_item(item_id)
        if not item:
            log.warning("update_status: item %s not found", item_id)
            return
        item["status"] = status
        item["updated_at"] = _utc_iso()
        # Clean up status cards on terminal state
        if status in ("done", "failed", "needs-input"):
            item["messages"] = [m for m in item["messages"]
                               if m.get("kind") != "status_card"]
        if agent_message:
            item["messages"].append({
                "id": _msg_id(), "sender": "agent",
                "content": agent_message, "timestamp": _utc_iso(),
                "kind": "text",
            })
        if error:
            item["error"] = {
                "code": error.get("code", "internal"),
                "message": error.get("message", "Unknown error"),
                "retryable": error.get("retryable", False),
                "timestamp": _utc_iso(),
            }
            item["messages"].append({
                "id": _msg_id(), "sender": "agent",
                "content": item["error"]["message"],
                "timestamp": _utc_iso(), "kind": "error",
            })
        if result_path:
            item["result_path"] = result_path
        self._write_item(item)
        self._update_manifest(item)

    def emit_status_card(self, item_id: str, text: str, icon: str = "gear"):
        """Emit a status card message (progress indicator)."""
        self.append_message(
            item_id, "agent",
            json.dumps({"type": "status", "text": text, "icon": icon},
                       ensure_ascii=False),
            kind="status_card",
        )

    def set_tags(self, item_id: str, tags: list[str]):
        """Update item tags."""
        item = self._read_item(item_id)
        if not item:
            return
        item["tags"] = tags
        item["updated_at"] = _utc_iso()
        self._write_item(item)
        self._update_manifest(item)

    def item_exists(self, item_id: str) -> bool:
        return (self.items_dir / f"{item_id}.json").exists()

    # ==================================================================
    # Sharing
    # ==================================================================

    def share_item(self, item_id: str):
        """Copy an item to shared/items/ so all users can see it."""
        item = self._read_item(item_id)
        if not item:
            return
        item["shared_by"] = self.user_id
        shared_items = self.bridge_dir / "shared" / "items"
        shared_items.mkdir(parents=True, exist_ok=True)
        _atomic_write(shared_items / f"{item_id}.json", item)

    # ==================================================================
    # Todo List
    # ==================================================================

    @property
    def todos_file(self) -> Path:
        return self.user_dir / "todos.json"

    def load_todos(self) -> list[dict]:
        if not self.todos_file.exists():
            return []
        try:
            return json.loads(self.todos_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return []

    def save_todos(self, todos: list[dict]):
        _atomic_write(self.todos_file, todos)

    def add_todo(self, title: str, priority: str = "medium",
                 tags: list[str] | None = None) -> dict:
        todos = self.load_todos()
        todo = {
            "id": f"todo_{uuid.uuid4().hex[:8]}",
            "title": title,
            "priority": priority,
            "status": "pending",
            "tags": tags or [],
            "created_at": _utc_iso(),
            "updated_at": _utc_iso(),
            "followups": [],
        }
        todos.append(todo)
        self.save_todos(todos)
        return todo

    def add_followup(self, todo_id: str, content: str,
                     source: str = "agent") -> dict | None:
        """Append a followup to a todo."""
        todos = self.load_todos()
        for t in todos:
            if t["id"] == todo_id:
                if "followups" not in t:
                    t["followups"] = []
                t["followups"].append({
                    "content": content,
                    "source": source,
                    "timestamp": _utc_iso(),
                })
                t["updated_at"] = _utc_iso()
                self.save_todos(todos)
                return t
        return None

    def update_todo(self, todo_id: str, status: str = "",
                    priority: str = "", title: str = "") -> dict | None:
        todos = self.load_todos()
        for t in todos:
            if t["id"] == todo_id:
                if status:
                    t["status"] = status
                if priority:
                    t["priority"] = priority
                if title:
                    t["title"] = title
                t["updated_at"] = _utc_iso()
                self.save_todos(todos)
                return t
        return None

    def remove_todo(self, todo_id: str):
        todos = [t for t in self.load_todos() if t["id"] != todo_id]
        self.save_todos(todos)

    def get_next_todo(self) -> dict | None:
        """Get highest priority pending todo."""
        todos = self.load_todos()
        pending = [t for t in todos if t["status"] == "pending"]
        if not pending:
            return None
        priority_order = {"high": 0, "medium": 1, "low": 2}
        pending.sort(key=lambda t: (priority_order.get(t["priority"], 1),
                                    t["created_at"]))
        return pending[0]

    # ==================================================================
    # Heartbeat
    # ==================================================================

    def heartbeat(self, busy: bool = False, active_count: int = 0,
                  agent_status: dict | None = None):
        """Write heartbeat so mobile app knows agent is alive."""
        data = {
            "timestamp": _utc_iso(),
            "status": "online",
            "busy": busy,
            "active_count": active_count,
        }
        if agent_status:
            data["agent_status"] = agent_status
        _atomic_write(self.heartbeat_file, data)

    # ==================================================================
    # Command polling (iOS -> agent)
    # ==================================================================

    def poll_commands(self) -> list[dict]:
        """Read command files from iOS with reliable delivery via ledger.

        Protocol:
        1. Read all command files from commands/ directory
        2. Check against ledger to skip already-processed commands
        3. Write ledger FIRST (crash-safe: worst case = re-process)
        4. Delete command files (best-effort, idempotent)
        """
        import shutil
        import tempfile

        try:
            subprocess.run(["brctl", "download", str(self.commands_dir)],
                           capture_output=True, timeout=10)
        except (FileNotFoundError, Exception):
            pass

        ledger = self._load_ledger()
        processed = ledger.get("processed", {})
        commands = []
        files_to_delete = []

        for path in sorted(self.commands_dir.glob("*.json")):
            if path.name.endswith(".tmp"):
                continue

            parts = path.stem.split("_")
            file_id = parts[-1] if len(parts) >= 4 else path.stem

            if file_id in processed:
                files_to_delete.append(path)
                continue

            data = self._try_read_command(path)
            if data is None:
                continue

            cmd_id = data.get("id", file_id)
            if cmd_id in processed:
                files_to_delete.append(path)
                continue

            commands.append(data)
            processed[cmd_id] = _utc_iso()
            files_to_delete.append(path)

        # Save ledger FIRST (crash-safe)
        if commands:
            ledger["processed"] = processed
            self._prune_ledger(ledger)
            self._save_ledger(ledger)

        # Delete files (best-effort)
        for path in files_to_delete:
            try:
                path.unlink()
            except OSError:
                pass

        # Drain pending queue
        pending_path = self.user_dir / ".pending_commands.json"
        if pending_path.exists():
            try:
                pending = json.loads(pending_path.read_text(encoding="utf-8"))
                if pending:
                    commands = pending + commands
                    pending_path.unlink()
            except (json.JSONDecodeError, OSError):
                pass

        return commands

    def requeue_command(self, cmd: dict):
        """Re-queue a command for next cycle (backpressure)."""
        pending_path = self.user_dir / ".pending_commands.json"
        pending = []
        if pending_path.exists():
            try:
                pending = json.loads(pending_path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                pending = []
        existing_ids = {c.get("item_id") for c in pending}
        if cmd.get("item_id") not in existing_ids:
            pending.append(cmd)
            _atomic_write(pending_path, pending)

    def _try_read_command(self, path: Path) -> dict | None:
        """Try to read a command file. Returns None if unreadable (iCloud placeholder)."""
        import shutil
        import tempfile
        try:
            tmp = Path(tempfile.mktemp(suffix=".json"))
            shutil.copy2(str(path), str(tmp))
            data = json.loads(tmp.read_text(encoding="utf-8"))
            tmp.unlink()
            return data
        except (OSError, shutil.Error, json.JSONDecodeError):
            pass
        try:
            _ensure_downloaded(path)
            time.sleep(0.5)
            data = json.loads(path.read_text(encoding="utf-8"))
            return data
        except (OSError, json.JSONDecodeError):
            return None

    def _load_ledger(self) -> dict:
        if self.ledger_file.exists():
            try:
                return json.loads(self.ledger_file.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                pass
        return {"processed": {}}

    def _save_ledger(self, ledger: dict):
        ledger["updated_at"] = _utc_iso()
        _atomic_write(self.ledger_file, ledger)

    def _prune_ledger(self, ledger: dict, max_age_days: int = 7):
        """Remove ledger entries older than max_age_days."""
        cutoff = datetime.now(timezone.utc) - timedelta(days=max_age_days)
        processed = ledger.get("processed", {})
        pruned = {}
        for cmd_id, ts in processed.items():
            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if dt > cutoff:
                    pruned[cmd_id] = ts
            except (ValueError, TypeError):
                pruned[cmd_id] = ts
        ledger["processed"] = pruned

    # ==================================================================
    # Maintenance
    # ==================================================================

    def archive_done_items(self, days: int = 7):
        """Archive stale items to keep the feed clean.

        Rules:
        - done/failed/completed older than `days` -> archive
        - queued older than `days` -> archive (stuck tasks)
        - working older than `days * 2` -> archive (dead tasks)
        - needs-input with no user reply older than 1 day -> archive
        - Corrupt JSON files older than 1 day -> delete
        - Pinned items are never archived.
        """
        now = datetime.now(timezone.utc)
        cutoff = now - timedelta(days=days)
        stuck_cutoff = now - timedelta(days=days * 2)
        stale_cutoff = now - timedelta(days=1)
        changed = False
        for path in list(self.items_dir.glob("*.json")):
            try:
                item = json.loads(path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                # Corrupt file — remove if old enough
                try:
                    if path.stat().st_mtime < stale_cutoff.timestamp():
                        path.unlink()
                        changed = True
                except OSError:
                    pass
                continue
            try:
                if item.get("pinned"):
                    continue
                updated = datetime.fromisoformat(
                    item["updated_at"].replace("Z", "+00:00"))
                status = item.get("status")

                should_archive = False
                if status in ("done", "failed", "completed") and updated < cutoff:
                    should_archive = True
                elif status == "queued" and updated < cutoff:
                    should_archive = True
                elif status == "working" and updated < stuck_cutoff:
                    should_archive = True
                elif status == "needs-input" and updated < stale_cutoff:
                    has_user_reply = any(
                        m.get("sender") == "user"
                        for m in item.get("messages", [])
                    )
                    if not has_user_reply:
                        should_archive = True

                if should_archive:
                    item["status"] = "archived"
                    _atomic_write(self.archive_dir / path.name, item)
                    path.unlink()
                    changed = True
            except KeyError:
                continue
        if changed:
            self._update_manifest()

    def cleanup_old(self, days: int = 7):
        """Alias for archive_done_items (called by super agent)."""
        self.archive_done_items(days=days)

    # ==================================================================
    # Manifest
    # ==================================================================

    def _update_manifest(self, changed_item: dict | None = None):
        """Update manifest.json. Incremental if possible, full rebuild otherwise."""
        if changed_item and self.manifest_file.exists():
            try:
                manifest = json.loads(self.manifest_file.read_text(encoding="utf-8"))
                items = manifest.get("items", [])
                item_id = changed_item["id"]

                found = False
                for i, entry in enumerate(items):
                    if entry.get("id") == item_id:
                        items[i] = {
                            "id": item_id,
                            "type": changed_item.get("type", "request"),
                            "status": changed_item.get("status", "queued"),
                            "updated_at": changed_item.get("updated_at", ""),
                        }
                        found = True
                        break
                if not found:
                    items.append({
                        "id": item_id,
                        "type": changed_item.get("type", "request"),
                        "status": changed_item.get("status", "queued"),
                        "updated_at": changed_item.get("updated_at", ""),
                    })

                manifest["items"] = items
                manifest["updated_at"] = _utc_iso()
                manifest["generation"] = manifest.get("generation", 0) + 1
                _atomic_write(self.manifest_file, manifest)
                return
            except (json.JSONDecodeError, OSError, KeyError):
                pass

        # Full rebuild
        entries = []
        for path in self.items_dir.glob("*.json"):
            if path.suffix == ".tmp":
                continue
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                entries.append({
                    "id": data["id"],
                    "type": data.get("type", "request"),
                    "status": data.get("status", "queued"),
                    "updated_at": data.get("updated_at", ""),
                })
            except (json.JSONDecodeError, OSError, KeyError):
                continue

        old_gen = 0
        if self.manifest_file.exists():
            try:
                old = json.loads(self.manifest_file.read_text(encoding="utf-8"))
                old_gen = old.get("generation", 0)
            except (json.JSONDecodeError, OSError):
                pass

        _atomic_write(self.manifest_file, {
            "updated_at": _utc_iso(),
            "generation": old_gen + 1,
            "items": entries,
        })

    # ==================================================================
    # Internal
    # ==================================================================

    def _read_item(self, item_id: str) -> dict | None:
        path = self.items_dir / f"{item_id}.json"
        if not path.exists():
            return None
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return None

    def _write_item(self, item: dict):
        _atomic_write(self.items_dir / f"{item['id']}.json", item)
