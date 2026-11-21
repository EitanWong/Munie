// Munie addition: explicit executable/project and source-fork boundary regressions; no real Codex.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { configuredRoot, scopedPath, bindNativeRequest, assertNativeMethod,
  createPendingResponseGate } = require('../src/munie-project-policy');
const { createCodexLaunchPlans } = require('../src/codex-transport');
const { readBridgeConfig } = require('../src/codex-desktop-refresher');
const { handleProjectMethod } = require('../src/project-handler');
const { handleGitRequest } = require('../src/git-handler');
const { handleWorkspaceRequest } = require('../src/workspace-handler');
const { execFileSync } = require('node:child_process');
const { isRelayBoundServerRequestMethod } = require('../src/bridge');

test('native replies and malformed methods never enter the approval response gate', () => {
  for (const response of [{ id: 1, result: {} }, { id: 2, error: { code: -1 } },
                         { id: 3, method: null }, { id: 4, method: 12 }]) {
    assert.equal(isRelayBoundServerRequestMethod(response.method), false);
  }
  assert.equal(isRelayBoundServerRequestMethod('item/commandExecution/requestApproval'), true);
  assert.equal(isRelayBoundServerRequestMethod('item/tool/requestUserInput'), true);
});

test('fixed launch plans use the exact executable/project and refuse missing executable without fallback', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'munie-remodex-plan-'));
  try {
    const executable = path.join(temporary, 'fixture-codex');
    fs.writeFileSync(executable, '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    const launches = createCodexLaunchPlans({ env: { REMODEX_CODEX_BINARY: executable,
      REMODEX_PROJECT_ROOT: temporary }, platform: 'darwin' });
    assert.equal(launches.length, 1);
    assert.equal(launches[0].command, fs.realpathSync(executable));
    assert.equal(launches[0].options.cwd, fs.realpathSync(temporary));
    assert.ok(launches[0].args.includes('approval_policy="on-request"'));
    assert.ok(launches[0].args.includes('sandbox_mode="workspace-write"'));
    assert.throws(() => createCodexLaunchPlans({ env: { REMODEX_CODEX_BINARY: executable + '-missing' } }));
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
});

test('canonical scope rejects sibling-prefix, traversal and symlink escapes, including new files', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'munie-remodex-scope-'));
  try {
    const root = path.join(temporary, 'project');
    const sibling = path.join(temporary, 'project-other');
    fs.mkdirSync(root); fs.mkdirSync(sibling);
    fs.symlinkSync(sibling, path.join(root, 'escape'));
    fs.symlinkSync(path.join(temporary, 'absent'), path.join(root, 'broken'));
    const canonicalRoot = fs.realpathSync(root);
    assert.equal(scopedPath('new/file.txt', { root: canonicalRoot, allowMissing: true }), path.join(canonicalRoot, 'new/file.txt'));
    for (const input of [sibling, '../project-other', 'escape', 'escape/new.txt', 'broken/new.txt']) {
      assert.throws(() => scopedPath(input, { root: canonicalRoot, allowMissing: true }));
    }
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
});

test('native mutations keep fixed cwd and user approvals while replacing client sandbox overrides', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'munie-remodex-native-'));
  try {
    const root = fs.realpathSync(temporary);
    const request = bindNativeRequest({ id: 1, method: 'turn/start', params: {
      input: [{ type: 'text', text: 'synthetic request' }], approvalPolicy: 'never', permissions: 'full',
      sandboxPolicy: { type: 'dangerFullAccess' } } }, root);
    assert.equal(request.params.cwd, root);
    assert.equal(request.params.approvalPolicy, 'on-request');
    assert.equal(request.params.approvalsReviewer, 'user');
    assert.equal(request.params.permissions, undefined);
    assert.deepEqual(request.params.sandboxPolicy.writableRoots, [root]);
    assert.equal(request.params.sandboxPolicy.networkAccess, false);
    assert.throws(() => bindNativeRequest({ method: 'git/status', params: { cwd: path.dirname(root) } }, root));
    assert.throws(() => bindNativeRequest({ method: 'workspace/readFile', params: { path: '/etc/passwd' } }, root));
    for (const method of ['desktop/preferences/update', 'desktop/bridge/updateAndRestart', 'desktop/continueOnMac', 'desktop/wakeDisplay']) {
      assert.throws(() => bindNativeRequest({ method, params: {} }, root));
    }
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
});

test('the phone may start browser login but may not set credential material', () => {
  const login = { id: 1, method: 'account/login/start' };
  assert.deepEqual(bindNativeRequest({ ...login, params: { type: 'chatgpt' } }, '/fixture'),
    { ...login, params: { type: 'chatgpt' } });
  for (const params of [
    { type: 'apiKey', apiKey: 'fixture-secret' },
    { type: 'chatgptAuthTokens', accessToken: 'fixture-secret' },
    { type: 'chatgpt', apiKey: 'fixture-secret' },
    { type: 'futureLogin' },
    null,
  ]) {
    assert.throws(() => bindNativeRequest({ ...login, params }, '/fixture'), (error) => {
      assert.match(error.message, /only be set on this Mac/);
      assert.doesNotMatch(error.message, /fixture-secret/);
      return true;
    });
  }
  const legacy = { ...login, params: { type: 'apiKey', apiKey: 'fixture-secret' } };
  assert.equal(bindNativeRequest(legacy, null), legacy);
});

test('the public QR endpoint is independent of the bridge loopback connection', () => {
  const config = readBridgeConfig({ env: { REMODEX_RELAY: 'ws://127.0.0.1:9275/relay',
    REMODEX_PUBLIC_RELAY: 'wss://fixture.invalid:8443/relay' } });
  assert.equal(config.relayUrl, 'ws://127.0.0.1:9275/relay');
  assert.equal(config.publicRelayUrl, 'wss://fixture.invalid:8443/relay');
});

test('generic native execution, configuration and future unknown methods require explicit policy', () => {
  for (const method of ['command/exec', 'config/value/write', 'config/batchWrite', 'fs/readFile', 'future/execute']) {
    assert.throws(() => assertNativeMethod({ method }, '/fixture'));
  }
  for (const method of ['thread/start', 'thread/read', 'turn/interrupt', 'turn/steer', 'model/list']) {
    assert.doesNotThrow(() => assertNativeMethod({ method }, '/fixture'));
  }
});

test('native config and future permission profiles cannot survive a bound thread request', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'munie-remodex-config-'));
  try {
    const root = fs.realpathSync(temporary);
    for (const field of ['config', 'permissionProfile', 'permission_profile']) {
      assert.throws(() => bindNativeRequest({ method: 'thread/start', params: {
        [field]: { mcp_servers: { fixture: { command: '/bin/echo', args: ['synthetic-only'] } } },
      } }, root));
    }
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
});

test('only one response matching a live server request may reach native', () => {
  const gate = createPendingResponseGate();
  assert.throws(() => gate.consume('forged-approval'));
  gate.remember('actual-approval');
  assert.doesNotThrow(() => gate.consume('actual-approval'));
  assert.throws(() => gate.consume('actual-approval'));
});

test('project discovery uses the configured root rather than the account home', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'munie-remodex-project-'));
  const previous = process.env.REMODEX_PROJECT_ROOT;
  try {
    process.env.REMODEX_PROJECT_ROOT = temporary;
    const result = await handleProjectMethod('project/listDirectory', {});
    assert.equal(fs.realpathSync(result.path), configuredRoot());
    await assert.rejects(handleProjectMethod('project/listDirectory', { path: path.dirname(temporary) }));
    await assert.rejects(handleProjectMethod('project/createRootlessChatRoot', {}));
  } finally {
    if (previous === undefined) delete process.env.REMODEX_PROJECT_ROOT;
    else process.env.REMODEX_PROJECT_ROOT = previous;
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('Git and workspace handlers reject outside cwd and parent repositories under an explicit grant', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'munie-remodex-handlers-'));
  const previous = process.env.REMODEX_PROJECT_ROOT;
  const invoke = (handler, method, params) => new Promise(resolve => {
    assert.equal(handler(JSON.stringify({ id: 'fixture', method, params }), value => resolve(JSON.parse(value))), true);
  });
  try {
    execFileSync('git', ['init', '-q', temporary]);
    const root = path.join(temporary, 'authorized-child');
    fs.mkdirSync(root);
    process.env.REMODEX_PROJECT_ROOT = root;
    const outside = await invoke(handleGitRequest, 'git/status', { cwd: temporary });
    assert.ok(outside.error);
    const parentRepo = await invoke(handleGitRequest, 'git/diff', { cwd: root });
    assert.ok(parentRepo.error);
    const file = await invoke(handleWorkspaceRequest, 'workspace/readFile', { cwd: root, path: path.join(temporary, 'outside.txt') });
    assert.ok(file.error);
    const worktree = await invoke(handleGitRequest, 'git/createWorktree', { cwd: root, name: 'fixture' });
    assert.ok(worktree.error);
    assert.deepEqual(fs.readdirSync(root), []);
  } finally {
    if (previous === undefined) delete process.env.REMODEX_PROJECT_ROOT;
    else process.env.REMODEX_PROJECT_ROOT = previous;
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});
