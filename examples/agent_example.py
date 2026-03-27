"""Example: Minimal agent using MiraBridge.

This agent runs in a loop, checking for commands from the iOS app,
processing them, and sending results back.
"""
import sys
import time
sys.path.insert(0, "../python")

from mira_bridge import Bridge

# Point to your iCloud Drive bridge folder
BRIDGE_DIR = "~/Library/Mobile Documents/com~apple~CloudDocs/MyApp/Bridge"

bridge = Bridge(BRIDGE_DIR, user_id="default")

print(f"Agent started. Watching: {bridge.bridge_dir}")

while True:
    # 1. Heartbeat — tells the iOS app we're alive
    bridge.heartbeat(busy=False)

    # 2. Poll for commands from the iOS app
    commands = bridge.poll_commands()

    for cmd in commands:
        cmd_type = cmd.get("type", "")
        content = cmd.get("content", "")
        item_id = cmd.get("item_id", "")
        title = cmd.get("title", content[:50])

        if cmd_type == "new_request":
            # Create the item and mark it as working
            bridge.create_item(item_id or f"req_{int(time.time())}",
                              "request", title, content)
            bridge.update_status(item_id, "working")
            bridge.emit_status_card(item_id, "Processing...", "gear")

            # --- Do your work here ---
            result = f"Processed: {content}"

            # Send the result back
            bridge.update_status(item_id, "done",
                                agent_message=result)

        elif cmd_type == "comment":
            # User replied to an existing item
            bridge.append_message(item_id, "user", content)
            # Process the reply...
            bridge.append_message(item_id, "agent", f"Got it: {content}")

        elif cmd_type == "cancel":
            bridge.update_status(item_id, "failed",
                                error={"code": "cancelled",
                                       "message": "Cancelled by user",
                                       "retryable": False})

    # 3. You can also create feed items (notifications to the user)
    # bridge.create_feed("daily_001", "Daily Summary", "Here's what happened today...")

    time.sleep(30)  # Check every 30 seconds
