import { spawn } from "node:child_process";
import readline from "node:readline";

const binary = process.env.CODEX_REMOTE_BIN || `${process.env.HOME}/.local/bin/codex-remote`;
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const child = spawn(binary, ["app-server", "--listen", "stdio://"], {
  stdio: ["pipe", "pipe", "pipe"],
  env: process.env,
  // The npm launcher starts the native Codex binary as its child. A dedicated process group lets
  // the smoke test remove both processes, including after a timeout.
  detached: true,
});
const lines = readline.createInterface({ input: child.stdout });
let stderr = "";

child.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

function processGroupAlive() {
  if (!child.pid) return false;
  try {
    process.kill(-child.pid, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    throw error;
  }
}

async function stop() {
  if (!processGroupAlive()) return;
  process.kill(-child.pid, "SIGTERM");
  const deadline = Date.now() + 5_000;
  while (processGroupAlive() && Date.now() < deadline) {
    await delay(50);
  }
  if (processGroupAlive()) {
    process.kill(-child.pid, "SIGKILL");
    const killDeadline = Date.now() + 5_000;
    while (processGroupAlive() && Date.now() < killDeadline) {
      await delay(50);
    }
    if (processGroupAlive()) throw new Error("Codex app-server process group did not stop");
  }
}

async function verify() {
  await new Promise((resolve, reject) => {
    let initialized = false;
    let sawThreads = false;
    let sawModels = false;
    let settled = false;
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve();
    };
    const timer = setTimeout(() => {
      finish(new Error(`Timed out waiting for app-server. ${stderr}`));
    }, 15_000);
    const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);

    child.on("error", (error) => finish(error));
    child.on("exit", (code, signal) => {
      if (!settled) {
        finish(new Error(`app-server exited before validation (code=${code}, signal=${signal}). ${stderr}`));
      }
    });
    child.stdin.on("error", (error) => finish(error));
    lines.on("line", (line) => {
      let message;
      try {
        message = JSON.parse(line);
      } catch (error) {
        finish(new Error(`app-server returned invalid JSON: ${error.message}`));
        return;
      }
      if (message.id === 1 && message.error) {
        finish(new Error(`initialize failed: ${JSON.stringify(message.error)}`));
        return;
      }
      if (message.id === 2 && message.error) {
        finish(new Error(`thread/list failed: ${JSON.stringify(message.error)}`));
        return;
      }
      if (message.id === 3 && message.error) {
        finish(new Error(`model/list failed: ${JSON.stringify(message.error)}`));
        return;
      }
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

      if (initialized && sawThreads && sawModels) finish();
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
  });
}

try {
  await verify();
  console.log("Codex app-server smoke test passed");
} finally {
  lines.close();
  await stop();
}
