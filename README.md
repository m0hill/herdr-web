# herdr-web

A small, responsive browser client for [Herdr](https://herdr.dev), rendered with [ghostty-web](https://github.com/coder/ghostty-web).

> This is an early prototype. It intentionally has no authentication. Only run it on a network you trust.

## What it does

Each browser connection starts a normal `herdr` client inside a PTY. Herdr's background server continues to own the workspaces, panes, and agents, so closing the browser only closes that browser's client.

The page adapts to desktop, tablet, and phone viewports, including mobile browser keyboards and safe areas. Touch devices get a compact row of terminal keys. Mouse clicks, dragging, and touch gestures are translated to Herdr's terminal mouse protocol, including pane resizing.

## Requirements

- macOS
- [Herdr](https://herdr.dev) available in `PATH`
- Zig 0.15.2+
- Bun

## Run

```bash
./dev.sh
```

Then open:

```text
http://YOUR-MAC-IP:7681
```

Find the Wi-Fi address on macOS with:

```bash
ipconfig getifaddr en0
```

Every open browser gets its own Herdr client. All of them attach to the same persistent Herdr session.

## Build

```bash
cd web
bun install
bun run build
cd ..
zig build
```

The built server is at `zig-out/bin/herdr-web` and serves `web/dist` from the current working directory.

## Current limitations

- No authentication or TLS.
- The first version targets macOS.
- Mouse and touch scrolling are translated to Herdr's terminal mouse protocol, but still need broader real-device testing.

## Acknowledgements

- Terminal rendering: [coder/ghostty-web](https://github.com/coder/ghostty-web), backed by Ghostty's terminal engine.
- PTY and WebSocket implementation patterns were informed by [Edward-lyz/Nexus](https://github.com/Edward-lyz/Nexus) and [tsl0922/ttyd](https://github.com/tsl0922/ttyd), both MIT licensed.
