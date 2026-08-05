import { FitAddon, Terminal, init } from "ghostty-web";
import "./style.css";

const terminalElement = requireElement("terminal");
const statusElement = requireElement("status");
const touchKeysElement = requireElement("touch-keys");

let socket: WebSocket | undefined;
let reconnectTimer: number | undefined;
let fitFrame: number | undefined;
let ctrlPending = false;

await init();

const terminal = new Terminal({
  cursorBlink: true,
  fontFamily: '"SFMono-Regular", "Cascadia Code", Menlo, monospace',
  fontSize: preferredFontSize(),
  scrollback: 10_000,
  smoothScrollDuration: 80,
  theme: {
    background: "#101216",
    foreground: "#e7e9ee",
    cursor: "#f3c969",
    selectionBackground: "#40506a",
    black: "#101216",
    red: "#e06c75",
    green: "#98c379",
    yellow: "#e5c07b",
    blue: "#61afef",
    magenta: "#c678dd",
    cyan: "#56b6c2",
    white: "#d7dae0",
  },
});

const fitAddon = new FitAddon();
terminal.loadAddon(fitAddon);
terminal.open(terminalElement);
fitAddon.fit();
fitAddon.observeResize();
terminal.attachCustomWheelEventHandler((event) => {
  const steps = Math.max(1, Math.min(5, Math.round(Math.abs(event.deltaY) / 32)));
  sendMouseWheel(event.deltaY < 0 ? "up" : "down", event.clientX, event.clientY, steps, event);
  return true;
});
installHerdrPointerInput();
installTouchInput();

terminal.onData((data) => {
  const outgoing = ctrlPending ? applyCtrl(data) : data;
  ctrlPending = false;
  renderCtrlState();
  sendInput(outgoing);
});

terminal.onResize(({ cols, rows }) => {
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ type: "resize", cols, rows }));
  }
});

window.addEventListener("resize", fitTerminal);
window.visualViewport?.addEventListener("resize", syncVisualViewport);
window.visualViewport?.addEventListener("scroll", syncVisualViewport);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) {
    syncVisualViewport();
    terminal.focus();
  }
});

touchKeysElement.addEventListener("click", (event) => {
  const target = event.target;
  if (!(target instanceof HTMLButtonElement)) return;

  if (target.dataset.modifier === "ctrl") {
    ctrlPending = !ctrlPending;
    renderCtrlState();
    terminal.focus();
    return;
  }

  const key = target.dataset.key;
  if (!key) return;
  const sequence = keySequence(key);
  sendInput(ctrlPending ? applyCtrl(sequence) : sequence);
  ctrlPending = false;
  renderCtrlState();
  terminal.focus();
});

syncVisualViewport();
connect();

function connect(): void {
  window.clearTimeout(reconnectTimer);
  setStatus("connecting", "Connecting…");

  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const url = new URL(`${protocol}//${location.host}/ws`);
  url.searchParams.set("cols", String(terminal.cols));
  url.searchParams.set("rows", String(terminal.rows));

  const nextSocket = new WebSocket(url);
  nextSocket.binaryType = "arraybuffer";
  socket = nextSocket;

  nextSocket.addEventListener("open", () => {
    setStatus("connected", "Connected");
    terminal.focus();
    fitTerminal();
  });

  nextSocket.addEventListener("message", (event) => {
    if (typeof event.data === "string") {
      terminal.write(event.data);
      return;
    }
    if (event.data instanceof ArrayBuffer) {
      terminal.write(new Uint8Array(event.data));
    }
  });

  nextSocket.addEventListener("close", () => {
    if (socket !== nextSocket) return;
    setStatus("disconnected", "Reconnecting…");
    reconnectTimer = window.setTimeout(connect, 1_500);
  });

  nextSocket.addEventListener("error", () => {
    if (socket === nextSocket) setStatus("disconnected", "Connection lost");
  });
}

function sendInput(data: string): void {
  if (socket?.readyState !== WebSocket.OPEN) return;
  socket.send(new TextEncoder().encode(data));
}

function sendMouseWheel(
  direction: "up" | "down",
  clientX: number,
  clientY: number,
  steps: number,
  modifiers?: Pick<MouseEvent, "shiftKey" | "altKey" | "ctrlKey">,
): void {
  const button = direction === "up" ? 64 : 65;
  sendInput(mouseSequence(button, clientX, clientY, false, modifiers).repeat(steps));
}

function mouseSequence(
  button: number,
  clientX: number,
  clientY: number,
  release: boolean,
  modifiers?: Pick<MouseEvent, "shiftKey" | "altKey" | "ctrlKey">,
): string {
  const bounds = terminalElement.getBoundingClientRect();
  const column = Math.max(1, Math.min(terminal.cols, Math.floor(((clientX - bounds.left) / bounds.width) * terminal.cols) + 1));
  const row = Math.max(1, Math.min(terminal.rows, Math.floor(((clientY - bounds.top) / bounds.height) * terminal.rows) + 1));
  let encodedButton = button;
  if (modifiers?.shiftKey) encodedButton += 4;
  if (modifiers?.altKey) encodedButton += 8;
  if (modifiers?.ctrlKey) encodedButton += 16;
  return `\u001b[<${encodedButton};${column};${row}${release ? "m" : "M"}`;
}

function installHerdrPointerInput(): void {
  let pressedButton: number | undefined;

  terminalElement.addEventListener(
    "pointerdown",
    (event) => {
      if (event.pointerType === "touch" || event.shiftKey) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      pressedButton = event.button;
      terminalElement.setPointerCapture(event.pointerId);
      sendInput(mouseSequence(event.button, event.clientX, event.clientY, false, event));
      terminal.focus();
    },
    { capture: true },
  );

  terminalElement.addEventListener(
    "pointermove",
    (event) => {
      if (event.pointerType === "touch" || pressedButton === undefined) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      sendInput(mouseSequence(32 + pressedButton, event.clientX, event.clientY, false, event));
    },
    { capture: true },
  );

  terminalElement.addEventListener(
    "pointerup",
    (event) => {
      if (event.pointerType === "touch" || pressedButton === undefined) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      sendInput(mouseSequence(pressedButton, event.clientX, event.clientY, true, event));
      pressedButton = undefined;
      terminalElement.releasePointerCapture(event.pointerId);
    },
    { capture: true },
  );

  terminalElement.addEventListener("contextmenu", (event) => event.preventDefault());
}

function installTouchInput(): void {
  let startX: number | undefined;
  let startY: number | undefined;
  let lastY: number | undefined;
  let accumulated = 0;
  let moved = false;

  terminalElement.addEventListener(
    "touchstart",
    (event) => {
      const touch = event.touches.item(0);
      startX = touch?.clientX;
      startY = touch?.clientY;
      lastY = touch?.clientY;
      accumulated = 0;
      moved = false;
    },
    { passive: true, capture: true },
  );

  terminalElement.addEventListener(
    "touchmove",
    (event) => {
      const touch = event.touches.item(0);
      if (!touch || lastY === undefined) return;
      accumulated += lastY - touch.clientY;
      lastY = touch.clientY;
      if (Math.abs(accumulated) >= 8) moved = true;
      const steps = Math.trunc(Math.abs(accumulated) / 18);
      if (steps === 0) return;
      event.preventDefault();
      sendMouseWheel(accumulated > 0 ? "down" : "up", touch.clientX, touch.clientY, Math.min(steps, 5));
      accumulated %= 18;
    },
    { passive: false, capture: true },
  );

  terminalElement.addEventListener(
    "touchend",
    () => {
      if (!moved && startX !== undefined && startY !== undefined) {
        sendInput(mouseSequence(0, startX, startY, false) + mouseSequence(0, startX, startY, true));
      }
      startX = undefined;
      startY = undefined;
      lastY = undefined;
      accumulated = 0;
      moved = false;
      terminal.focus();
    },
    { passive: true, capture: true },
  );
}

function syncVisualViewport(): void {
  const viewport = window.visualViewport;
  const height = viewport?.height ?? window.innerHeight;
  const top = viewport?.offsetTop ?? 0;
  document.documentElement.style.setProperty("--viewport-height", `${Math.round(height)}px`);
  document.documentElement.style.setProperty("--viewport-top", `${Math.round(top)}px`);
  fitTerminal();
}

function fitTerminal(): void {
  if (fitFrame !== undefined) return;
  fitFrame = window.requestAnimationFrame(() => {
    fitFrame = undefined;
    fitAddon.fit();
  });
}

function setStatus(state: "connecting" | "connected" | "disconnected", text: string): void {
  statusElement.dataset.state = state;
  statusElement.textContent = text;
}

function preferredFontSize(): number {
  if (window.matchMedia("(max-width: 520px)").matches) return 12;
  if (window.matchMedia("(max-width: 900px)").matches) return 13;
  return 14;
}

function applyCtrl(data: string): string {
  if (data.length !== 1) return data;
  const code = data.toUpperCase().charCodeAt(0);
  if (code >= 64 && code <= 95) return String.fromCharCode(code - 64);
  return data;
}

function keySequence(key: string): string {
  switch (key) {
    case "escape":
      return "\u001b";
    case "tab":
      return "\t";
    case "enter":
      return "\r";
    case "arrowup":
      return "\u001b[A";
    case "arrowdown":
      return "\u001b[B";
    case "arrowright":
      return "\u001b[C";
    case "arrowleft":
      return "\u001b[D";
    default:
      return "";
  }
}

function renderCtrlState(): void {
  const button = touchKeysElement.querySelector<HTMLButtonElement>('[data-modifier="ctrl"]');
  button?.toggleAttribute("data-active", ctrlPending);
}

function requireElement(id: string): HTMLElement {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing required element #${id}`);
  return element;
}
