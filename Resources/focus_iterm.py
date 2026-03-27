#!/usr/bin/env python3
"""Focus a specific iTerm2 session by UUID."""

import sys
import iterm2


async def main(connection):
    if len(sys.argv) < 2:
        print("Usage: focus_iterm.py <session-uuid>", file=sys.stderr)
        sys.exit(1)

    session_id = sys.argv[1]
    app = await iterm2.async_get_app(connection)
    session = app.get_session_by_id(session_id)

    if session is None:
        print(f"Session not found: {session_id}", file=sys.stderr)
        sys.exit(1)

    await session.async_activate(select_tab=True, order_window_front=True)


iterm2.run_until_complete(main)
