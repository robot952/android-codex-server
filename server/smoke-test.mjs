import { spawn } from "node:child_process";
import readline from "node:readline";

const binary = process.env.CODEX_REMOTE_BIN || `${process.env.HOME}/.local/bin/codex-remote`;
const child = spawn(binary, ["app-server", "--listen", "stdio://"], {
  stdio: ["pipe", "pipe", "pipe"],
  env: process.env,
});
const lines = readline.createInterface({ input: child.stdout });
let initialized = false;
let sawThreads = false;
let sawModels = false;
let stderr = "";

child.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);
const timer = setTimeout(() => {
  child.kill("SIGTERM");
  console.error(`Timed out waiting for app-server. ${stderr}`);
  process.exitCode = 1;
}, 15000);

lines.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.id === 1 && message.result) {
    initialized = true;
    send({ method: "initialized", params: {} });
    send({ method: "thread/list", id: 2, params: { limit: 10, sortKey: "recency_at", sortDirection: "desc" } });
    send({ method: "model/list", id: 3, params: { limit: 50 } });
  } else if (message.id === 2 && message.result) {
    sawThreads = Array.isArray(message.result.data);
    console.log(`thread/list: ${message.result.data?.length ?? 0} threads`);
  } else if (message.id === 3 && message.result) {
    sawModels = Array.isArray(message.result.data);
    console.log(`model/list: ${message.result.data?.length ?? 0} models`);
  }

  if (initialized && sawThreads && sawModels) {
    clearTimeout(timer);
    child.kill("SIGTERM");
    console.log("Codex app-server smoke test passed");
  }
});

child.on("exit", (code, signal) => {
  clearTimeout(timer);
  if (!(initialized && sawThreads && sawModels)) {
    console.error(`app-server exited before validation (code=${code}, signal=${signal}). ${stderr}`);
    process.exitCode = 1;
  }
});

send({
  method: "initialize",
  id: 1,
  params: {
    clientInfo: {
      name: "codex_remote_android_smoke_test",
      title: "Codex Remote Android smoke test",
      version: "1.0.0",
    },
  },
});
