import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const captureScript = path.join(root, "capture.ps1");
const hotkeyScript = path.join(root, "hotkey.ps1");
const outputDirectory = path.resolve(root, "../agent/temp/runtime");
const latestScreenshot = path.join(outputDirectory, "last.png");

const captureTool = {
  name: "capture_screenshot",
  title: "Capture Windows screenshot",
  description:
    "Capture the active window or the full Windows desktop and return it as an image.",
  inputSchema: {
    type: "object",
    properties: {
      mode: {
        type: "string",
        enum: ["window", "screen"],
        description:
          "window captures the active window; screen captures all monitors."
      }
    },
    required: ["mode"],
    additionalProperties: false
  },
  annotations: {
    readOnlyHint: true,
    destructiveHint: false,
    openWorldHint: false
  }
};

const latestTool = {
  name: "get_last_screenshot",
  title: "Read latest region screenshot",
  description:
    "Return the latest region screenshot created with the Ctrl+Shift+2 global hotkey.",
  inputSchema: {
    type: "object",
    properties: {},
    additionalProperties: false
  },
  annotations: {
    readOnlyHint: true,
    destructiveHint: false,
    openWorldHint: false
  }
};

function startHotkeyHelper() {
  fs.mkdirSync(outputDirectory, { recursive: true });
  const child = spawn(
    "powershell.exe",
    [
      "-NoLogo",
      "-NoProfile",
      "-STA",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      hotkeyScript
    ],
    { detached: true, windowsHide: true, stdio: "ignore" }
  );
  child.unref();
}

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function runCapture(mode, outputPath) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "powershell.exe",
      [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-STA",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        captureScript,
        "-Mode",
        mode,
        "-OutputPath",
        outputPath
      ],
      { windowsHide: true }
    );

    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
      } else if (code === 2) {
        reject(new Error("Screenshot selection was cancelled."));
      } else {
        reject(new Error(stderr.trim() || `Screenshot process exited with code ${code}.`));
      }
    });
  });
}

async function capture(mode) {
  if (!captureTool.inputSchema.properties.mode.enum.includes(mode)) {
    throw new Error(`Unsupported capture mode: ${mode}`);
  }

  fs.mkdirSync(outputDirectory, { recursive: true });
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const outputPath = path.join(outputDirectory, `${mode}-${timestamp}.png`);
  await runCapture(mode, outputPath);

  const data = fs.readFileSync(outputPath).toString("base64");
  return {
    content: [
      { type: "image", data, mimeType: "image/png" },
      { type: "text", text: `Screenshot captured and saved to ${outputPath}` }
    ]
  };
}

function getLatestScreenshot() {
  if (!fs.existsSync(latestScreenshot)) {
    throw new Error(
      "No region screenshot is available. Press Ctrl+Shift+2, drag a region, then try again."
    );
  }

  const data = fs.readFileSync(latestScreenshot).toString("base64");
  const capturedAt = fs.statSync(latestScreenshot).mtime.toISOString();
  return {
    content: [
      { type: "image", data, mimeType: "image/png" },
      {
        type: "text",
        text: `Latest region screenshot captured at ${capturedAt} and saved to ${latestScreenshot}`
      }
    ]
  };
}

async function handle(message) {
  if (message.method === "initialize") {
    return {
      protocolVersion: message.params?.protocolVersion || "2025-06-18",
      capabilities: { tools: {} },
      serverInfo: { name: "screen-capture", version: "0.2.3" }
    };
  }

  if (message.method === "ping") {
    return {};
  }

  if (message.method === "tools/list") {
    return { tools: [captureTool, latestTool] };
  }

  if (message.method === "tools/call") {
    if (message.params?.name === captureTool.name) {
      return capture(message.params?.arguments?.mode);
    }
    if (message.params?.name === latestTool.name) {
      return getLatestScreenshot();
    }
    throw new Error(`Unknown tool: ${message.params?.name}`);
  }

  throw new Error(`Method not found: ${message.method}`);
}

startHotkeyHelper();

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

for await (const line of input) {
  if (!line.trim()) continue;

  let message;
  try {
    message = JSON.parse(line);
  } catch {
    continue;
  }

  if (message.id === undefined) continue;

  try {
    send({ jsonrpc: "2.0", id: message.id, result: await handle(message) });
  } catch (error) {
    send({
      jsonrpc: "2.0",
      id: message.id,
      error: { code: -32603, message: error instanceof Error ? error.message : String(error) }
    });
  }
}
