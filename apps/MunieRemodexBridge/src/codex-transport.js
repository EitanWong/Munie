// Munie modification: explicit local launcher, project/runtime binding, or isolated state.
// FILE: codex-transport.js
// Purpose: Abstracts the Codex-side transport so the bridge can talk to either a spawned app-server or an existing WebSocket endpoint.
// Layer: CLI helper
// Exports: createCodexTransport
// Depends on: child_process, fs, path, ws

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const WebSocket = require("ws");
const { resolveBundledCodexCommand, resolveCodexAppPath } = require("./codex-desktop-app");

function createCodexTransport({
  endpoint = "",
  env = process.env,
  appPath = "",
  platform = process.platform,
  spawnImpl = spawn,
  WebSocketImpl = WebSocket,
} = {}) {
  if (endpoint) {
    return createWebSocketTransport({ endpoint, WebSocketImpl });
  }

  return createSpawnTransport({ env, appPath, platform, spawnImpl });
}

function createSpawnTransport({ env, appPath, platform, spawnImpl = spawn }) {
  const launchPlans = createCodexLaunchPlans({ env, appPath, platform });
  let launchIndex = -1;
  let activeLaunch = null;
  let codex = null;
  let stdoutBuffer = "";
  let stderrBuffer = "";
  let didRequestShutdown = false;
  let didReportError = false;
  const listeners = createListenerBag();

  spawnNextLaunch();

  return {
    mode: "spawn",
    describe() {
      return activeLaunch?.description || launchPlans[0]?.description || "`codex app-server`";
    },
    send(message) {
      if (!codex.stdin.writable || codex.stdin.destroyed || codex.stdin.writableEnded) {
        return;
      }

      codex.stdin.write(message.endsWith("\n") ? message : `${message}\n`);
    },
    onMessage(handler) {
      listeners.onMessage = handler;
    },
    onClose(handler) {
      listeners.onClose = handler;
    },
    onError(handler) {
      listeners.onError = handler;
    },
    onStarted(handler) {
      listeners.onStarted = handler;
    },
    shutdown() {
      didRequestShutdown = true;
      shutdownCodexProcess(codex);
    },
  };

  // Retries the launch once with the bundled desktop binary when the shell-visible
  // `codex` command is unavailable in daemon environments like launchd.
  function spawnNextLaunch() {
    launchIndex += 1;
    activeLaunch = launchPlans[launchIndex] || null;
    if (!activeLaunch) {
      return;
    }

    stdoutBuffer = "";
    stderrBuffer = "";
    codex = spawnImpl(activeLaunch.command, activeLaunch.args, activeLaunch.options);
    attachChildListeners(codex, activeLaunch);
  }

  function attachChildListeners(child, launch) {
    child.on("spawn", () => {
      if (child !== codex) {
        return;
      }

      listeners.emitStarted({
        mode: "spawn",
        launchDescription: launch.description,
      });
    });
    child.on("error", (error) => {
      if (child !== codex) {
        return;
      }

      if (!didRequestShutdown && shouldRetryLaunchError(error, launchIndex, launchPlans)) {
        spawnNextLaunch();
        return;
      }

      didReportError = true;
      listeners.emitError(error);
    });
    child.on("close", (code, signal) => {
      if (child !== codex) {
        return;
      }

      if (!didRequestShutdown && !didReportError && code !== 0) {
        didReportError = true;
        listeners.emitError(createCodexCloseError({
          code,
          signal,
          stderrBuffer,
          launchDescription: launch.description,
        }));
        return;
      }

      listeners.emitClose(code, signal);
    });
    // Ignore broken-pipe shutdown noise once the child is already going away.
    child.stdin.on("error", (error) => {
      if (child !== codex) {
        return;
      }

      if (didRequestShutdown && isIgnorableStdinShutdownError(error)) {
        return;
      }

      if (isIgnorableStdinShutdownError(error)) {
        return;
      }

      didReportError = true;
      listeners.emitError(error);
    });
    // Keep stderr muted during normal operation, but preserve enough output to
    // explain launch failures when the child exits before the bridge can use it.
    child.stderr.on("data", (chunk) => {
      if (child !== codex) {
        return;
      }
      stderrBuffer = appendOutputBuffer(stderrBuffer, chunk.toString("utf8"));
    });

    child.stdout.on("data", (chunk) => {
      if (child !== codex) {
        return;
      }
      stdoutBuffer += chunk.toString("utf8");
      let newlineIndex;
      while ((newlineIndex = stdoutBuffer.indexOf("\n")) !== -1) {
        const line = stdoutBuffer.substring(0, newlineIndex).trim();
        stdoutBuffer = stdoutBuffer.substring(newlineIndex + 1);
        if (line) {
          listeners.emitMessage(line);
        }
      }
    });
  }
}

// Make explicit Desktop handoff responsive after unsubscribe. Codex unloads
// only unsubscribed, inactive threads, and this override stays in our child.
const LOCAL_APP_SERVER_ARGS = ["app-server", "-c", "thread_unload_delay_secs=1"];

function sharedCodexPermissionArgs(env, fsImpl, pathImpl) {
  const { SHARED_CODEX_PERMISSIONS, SHARED_CODEX_APPROVAL, withinRoot } = require("./munie-project-policy");
  function canonical(file) {
    if (!pathImpl.isAbsolute(file)) throw new Error("Expected an absolute local directory.");
    return fsImpl.existsSync(file) ? fsImpl.realpathSync(file) : file;
  }
  // Inline TOML keys are quoted so owner-controlled paths cannot inject CLI settings.
  const home = canonical(env.CODEX_HOME || pathImpl.join(env.HOME, ".codex"));
  const state = canonical(env.MUNIE_HOST_STATE_DIR);
  const project = canonical(env.REMODEX_PROJECT_ROOT);
  if ([home, state].some((directory) => withinRoot(project, directory) || withinRoot(directory, project))) {
    throw new Error("The authorized project cannot overlap private runtime data.");
  }
  const rules = new Map([[":minimal", "read"], [project, "write"], [home, "deny"], [state, "deny"]]);
  const filesystem = [...rules].map(([key, value]) => `${JSON.stringify(key)}=${JSON.stringify(value)}`).join(",");
  const approval = Object.entries(SHARED_CODEX_APPROVAL.granular).map(([key, value]) => `${key}=${value}`).join(",");
  return ["-c", `approval_policy={granular={${approval}}}`,
    "-c", `default_permissions=${JSON.stringify(SHARED_CODEX_PERMISSIONS)}`,
    "-c", `permissions={${SHARED_CODEX_PERMISSIONS}={filesystem={${filesystem}},network={enabled=false}}}`,
    "-c", 'shell_environment_policy.inherit="core"'];
}

// Builds a single, platform-aware launch path so the bridge never "guesses"
// between multiple commands and accidentally starts duplicate runtimes.
function createCodexLaunchPlans({
  env,
  appPath = "",
  platform = process.platform,
  fsImpl = fs,
  pathImpl = path,
} = {}) {
  const sharedOptions = {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...env },
  };

  if (platform === "win32") {
    return [{
      command: env.ComSpec || "cmd.exe",
      args: ["/d", "/c", `codex ${LOCAL_APP_SERVER_ARGS.join(" ")}`],
      options: {
        ...sharedOptions,
        windowsHide: true,
      },
      description: "`cmd.exe /d /c codex app-server`",
    }];
  }

  // Munie modification: an explicit binary is the only launch plan; no PATH/Desktop fallback.
  if (env.REMODEX_CODEX_BINARY) {
    const command = fsImpl.realpathSync(env.REMODEX_CODEX_BINARY);
    if (!pathImpl.isAbsolute(env.REMODEX_CODEX_BINARY) || !fsImpl.statSync(command).isFile()) {
      throw new Error("REMODEX_CODEX_BINARY must name an absolute executable file.");
    }
    fsImpl.accessSync(command, fs.constants.X_OK);
    const sandboxArgs = env.MUNIE_FOLLOW_CODEX_ACCOUNT === "1"
      ? sharedCodexPermissionArgs(env, fsImpl, pathImpl)
      : ["-c", 'approval_policy="on-request"', "-c", 'sandbox_mode="workspace-write"'];
    return [{ command, args: [...LOCAL_APP_SERVER_ARGS, ...sandboxArgs],
      options: { ...sharedOptions, ...(env.REMODEX_PROJECT_ROOT ? { cwd: fsImpl.realpathSync(env.REMODEX_PROJECT_ROOT) } : {}) },
      description: `explicit Codex ${command}` }];
  }

  const launches = [{
    command: "codex",
    args: LOCAL_APP_SERVER_ARGS,
    options: sharedOptions,
    description: "`codex app-server`",
  }];

  const bundledCommand = resolveBundledCodexCommand(
    resolveCodexAppPath({ appPath, platform, homeDir: env.HOME, fsImpl }),
    { fsImpl, pathImpl }
  );
  if (bundledCommand) {
    launches.push({
      command: bundledCommand,
      args: LOCAL_APP_SERVER_ARGS,
      options: sharedOptions,
      description: `\`${bundledCommand} app-server\``,
    });
  }

  return launches;
}

// Stops the exact process tree we launched on Windows so the shell wrapper
// does not leave a child Codex process running in the background.
function shutdownCodexProcess(codex) {
  if (codex.killed || codex.exitCode !== null) {
    return;
  }

  if (process.platform === "win32" && codex.pid) {
    const killer = spawn("taskkill", ["/pid", String(codex.pid), "/t", "/f"], {
      stdio: "ignore",
      windowsHide: true,
    });
    killer.on("error", () => {
      codex.kill();
    });
    return;
  }

  codex.kill("SIGTERM");
}

function createCodexCloseError({ code, signal, stderrBuffer, launchDescription }) {
  const details = stderrBuffer.trim();
  const reason = details || `Process exited with code ${code}${signal ? ` (signal: ${signal})` : ""}.`;
  return new Error(formatCodexLaunchFailure({
    launchDescription,
    reason,
  }));
}

// Turns common Codex auth/config failures into recovery guidance without handling secrets in Remodex.
function formatCodexLaunchFailure({ launchDescription, reason }) {
  const message = `Codex launcher ${launchDescription} failed: ${reason}`;
  const missingEnvVar = extractMissingEnvironmentVariable(reason);
  if (!missingEnvVar) {
    return message;
  }

  const guidance = [
    `Codex is asking for ${missingEnvVar}, which usually means your Codex config forces API-key auth or a custom provider env var.`,
    "Remodex does not store or forward OpenAI API keys.",
    "Recommended fix: run `codex login` on this Mac, then restart Remodex.",
    "If you intentionally use API-key auth, run `printenv OPENAI_API_KEY | codex login --with-api-key` or make that env var available to the Remodex daemon yourself.",
  ];
  return `${message}\n${guidance.join("\n")}`;
}

function extractMissingEnvironmentVariable(reason) {
  const match = String(reason || "").match(/Missing environment variable:\s*`?([A-Za-z_][A-Za-z0-9_]*)`?/i);
  return match ? match[1] : "";
}

function appendOutputBuffer(buffer, chunk) {
  const next = `${buffer}${chunk}`;
  return next.slice(-4_096);
}

function isIgnorableStdinShutdownError(error) {
  return error?.code === "EPIPE" || error?.code === "ERR_STREAM_DESTROYED";
}

function shouldRetryLaunchError(error, launchIndex, launchPlans) {
  return error?.code === "ENOENT" && launchIndex < launchPlans.length - 1;
}

function createWebSocketTransport({ endpoint, WebSocketImpl = WebSocket }) {
  const socket = new WebSocketImpl(endpoint);
  const listeners = createListenerBag();
  const openState = WebSocketImpl.OPEN ?? WebSocket.OPEN ?? 1;
  const connectingState = WebSocketImpl.CONNECTING ?? WebSocket.CONNECTING ?? 0;

  socket.on("message", (chunk) => {
    const message = typeof chunk === "string" ? chunk : chunk.toString("utf8");
    if (message.trim()) {
      listeners.emitMessage(message);
    }
  });
  socket.on("open", () => {
    listeners.emitStarted({
      mode: "websocket",
      launchDescription: endpoint,
    });
  });

  socket.on("close", (code, reason) => {
    const safeReason = reason ? reason.toString("utf8") : "no reason";
    listeners.emitClose(code, safeReason);
  });

  socket.on("error", (error) => listeners.emitError(error));

  return {
    mode: "websocket",
    describe() {
      return endpoint;
    },
    send(message) {
      if (socket.readyState === openState) {
        socket.send(message);
      }
    },
    onMessage(handler) {
      listeners.onMessage = handler;
    },
    onClose(handler) {
      listeners.onClose = handler;
    },
    onError(handler) {
      listeners.onError = handler;
    },
    onStarted(handler) {
      listeners.onStarted = handler;
    },
    shutdown() {
      if (socket.readyState === openState || socket.readyState === connectingState) {
        socket.close();
      }
    },
  };
}

function createListenerBag() {
  return {
    onMessage: null,
    onClose: null,
    onError: null,
    onStarted: null,
    emitMessage(message) {
      this.onMessage?.(message);
    },
    emitClose(...args) {
      this.onClose?.(...args);
    },
    emitError(error) {
      this.onError?.(error);
    },
    emitStarted(info) {
      this.onStarted?.(info);
    },
  };
}

module.exports = {
  createCodexLaunchPlans,
  createCodexTransport,
  extractMissingEnvironmentVariable,
  formatCodexLaunchFailure,
};
