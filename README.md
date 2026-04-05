# MiraBridge

A zero-infrastructure communication layer between a local agent (Python on Mac) and a mobile app (SwiftUI on iPhone) using iCloud Drive as the canonical message bus.

No always-on backend is required. Just files synced by iCloud. An optional local HTTP mirror can sit on top for faster reads, but the file protocol remains the source of truth.

## Why?

If you're building a local AI agent that runs on your Mac and want to control it from your phone, you normally need a server, authentication, push notifications, etc. MiraBridge replaces the required backend with a shared folder on iCloud Drive. Your agent writes files; your phone reads them. Your phone writes commands; your agent reads them. iCloud handles the sync. If you later add a trusted local HTTP mirror, the app can read heartbeat and changed items faster without changing the write protocol.

## Architecture

```
+-------------+     iCloud Drive      +-------------+
|  Mac Agent  | <----- files -------> |  iPhone App  |
|  (Python)   |                       |  (SwiftUI)   |
|             |                       |              |
|  Bridge()   |    ~/Library/Mobile   | SyncEngine   |
|  .heartbeat |    Documents/iCloud/  | ItemStore    |
|  .poll      |    MyApp-Bridge/      | CommandWriter|
|  .create    |                       | BridgeConfig |
|  .update    |                       |              |
+-------------+                       +-------------+
```

Optional read acceleration:

```
iPhone App -- HTTP GET --> Local mirror (heartbeat / manifest / item reads only)
```

## Quick Start

### Python (Agent Side)

```python
from mira_bridge import Bridge

# Point to a folder inside iCloud Drive
bridge = Bridge("~/Library/Mobile Documents/com~apple~CloudDocs/MyApp/Bridge",
                user_id="ang")

# Tell the phone you're alive
bridge.heartbeat()

# Check for commands from the phone
for cmd in bridge.poll_commands():
    if cmd["type"] == "new_request":
        item_id = cmd["item_id"]
        bridge.update_status(item_id, "working")

        # ... do work ...

        bridge.update_status(item_id, "done",
                             agent_message="Here's your result!")

# Push a notification to the phone
bridge.create_feed("update_001", "Status Update", "Processing complete.")
```

### Swift (iOS App Side)

Add the Swift package from `swift/` to your Xcode project, then:

```swift
import MiraBridge

@Observable class AppState {
    let config = BridgeConfig()
    let store = ItemStore()
    let sync: SyncEngine
    let writer: CommandWriter

    init() {
        sync = SyncEngine(config: config, store: store)
        writer = CommandWriter(config: config, store: store)
    }
}

// Send a request to the agent
writer.createRequest(title: "Summarize this", content: "...")

// Check if agent is online
if sync.agentOnline { ... }

// Read items
for item in store.activeRequests { ... }
```

## Protocol

### Directory Structure

```
MyApp-Bridge/
├── heartbeat.json              <- Agent writes every ~30s
├── profiles.json               <- User registry (optional)
├── users/
│   └── {user_id}/
│       ├── manifest.json       <- Index of all items (agent-owned)
│       ├── items/              <- One JSON file per item (agent-owned)
│       │   ├── req_001.json
│       │   ├── feed_daily.json
│       │   └── disc_chat.json
│       ├── commands/           <- iOS writes, agent reads + deletes
│       │   └── cmd_20260326_120000_abc123.json
│       ├── command_ledger.json <- Reliable delivery tracking
│       ├── todos.json          <- Shared todo list
│       ├── health/
│       │   ├── health_summary.json  <- Agent writes metrics + trends
│       │   ├── apple_health_export.json  <- iOS writes (background)
│       │   └── checkups/       <- iOS writes checkup photos
│       └── archive/            <- Old items moved here
└── shared/                     <- Cross-user items (optional)
    └── items/
```

### Item Schema

```json
{
  "id": "req_001",
  "type": "request | discussion | feed",
  "title": "Do something",
  "status": "queued | working | needs-input | done | failed | archived",
  "tags": ["urgent"],
  "origin": "user | agent",
  "pinned": false,
  "quick": false,
  "parent_id": "",
  "created_at": "2026-03-26T12:00:00.000Z",
  "updated_at": "2026-03-26T12:01:00.000Z",
  "messages": [
    {
      "id": "a1b2c3d4",
      "sender": "user | agent",
      "content": "Please do this thing",
      "timestamp": "2026-03-26T12:00:00.000Z",
      "kind": "text | status_card | error"
    }
  ],
  "error": null,
  "result_path": null
}
```

Note: The Swift decoder is fault-tolerant -- missing `pinned`, `quick`, or `origin` fields get defaults. The `sender` field in messages also accepts the legacy `role` key.

## Optional HTTP Mirror

Some apps use a local HTTP mirror for lower-latency reads when the Mac and phone are on the same network. The common read endpoints are:

- `GET /api/heartbeat`
- `GET /api/{user_id}/manifest`
- `GET /api/{user_id}/items/{item_id}`

This mirror is optional and read-through only. Commands, ledgers, manifests, and item ownership still live in the file protocol above. In the Mira repo, this mirror is implemented in `web/server.py` and is limited to known users.

### Command Schema (iOS -> Agent)

```json
{
  "id": "abc12345",
  "type": "new_request | comment | reply | cancel | archive | pin",
  "timestamp": "2026-03-26T12:00:00.000Z",
  "sender": "iphone",
  "title": "Do something",
  "content": "Details here",
  "item_id": "req_001",
  "tags": ["urgent"]
}
```

### Health Summary (Agent -> iOS)

```json
{
  "person_id": "ang",
  "updated_at": "2026-03-30T14:00:00Z",
  "latest": {
    "weight": {"value": 72.5, "unit": "kg", "date": "2026-03-30"},
    "hrv": {"value": 46.0, "unit": "ms", "date": "2026-03-30"}
  },
  "trends": {
    "weight": [{"value": 72.5, "date": "2026-03-01"}, ...],
    "sleep_hours": [...]
  },
  "stats_7d": {
    "weight": {"avg": 72.3, "min": 71.8, "max": 72.8, "count": 7}
  },
  "notes": [
    {"date": "2026-03-30", "category": "symptom", "content": "headache"}
  ]
}
```

### Heartbeat

```json
{
  "timestamp": "2026-03-26T12:00:00.000Z",
  "status": "online",
  "busy": false,
  "active_count": 0
}
```

The iOS app considers the agent "online" if the heartbeat timestamp is within the last 180 seconds.

## Key Design Decisions

### Atomic Writes
All file writes use a tmp-file + rename pattern. This prevents the iOS app from reading a half-written JSON file during iCloud sync.

### Ledger-Based Command Delivery
Commands use a two-phase protocol:
1. iOS writes a command file to `commands/`
2. Agent reads it, records the command ID in `command_ledger.json`
3. Agent deletes the command file

If the agent crashes between steps 2 and 3, the ledger prevents re-processing on restart. If it crashes before step 2, the command file is still there and will be picked up next cycle.

### Manifest for Efficient Sync
The iOS app doesn't scan every item file on each poll. Instead, it reads `manifest.json` (a lightweight index), compares timestamps with its local cache, and only fetches items that changed.

### Fault-Tolerant Decoding
The Swift models use custom `init(from:)` decoders that provide defaults for missing fields. This prevents a single malformed item from breaking the entire sync. Legacy field names (e.g., `role` instead of `sender`) are accepted via fallback keys.

### iCloud Placeholder Handling
iCloud Drive may show a file as present but only download it on demand (cloud placeholder). The Python side uses `brctl download` to force downloads. The Swift side uses `startDownloadingUbiquitousItem()`. Both sides have retry logic for files that aren't immediately available.

### Multi-User Support
Each user gets their own namespace under `users/{user_id}/`. A single agent can serve multiple users by iterating `Bridge.for_all_users()`.

## Requirements

- **Python**: 3.11+ (stdlib only, no dependencies)
- **Swift**: 5.10+, iOS 17+ / macOS 14+
- **iCloud Drive** enabled on both Mac and iPhone
- Both devices signed into the same Apple ID

## License

MIT
