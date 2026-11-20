// Munie modification: distinguish app-managed and standalone package-update capabilities.
// FILE: account-status.js
// Purpose: Converts raw codex account/auth responses into a sanitized status payload for the phone UI.
// Layer: CLI helper
// Exports: composeAccountStatus, composeSanitizedAuthStatusFromSettledResults, redactAuthStatus
// Depends on: none

const { version: bridgePackageVersion = "" } = require("../package.json");

// ─── Status composition ─────────────────────────────────────

function redactNativeProviderError(frame) {
  if (!frame || typeof frame !== "object") return frame;
  const diagnostic = "The model service request failed. Check the API configuration on this Mac.";
  const redact = (error) => {
    const info = error.codexErrorInfo;
    const flags = ["httpConnectionFailed", "responseStreamConnectionFailed",
      "responseStreamDisconnected", "responseTooManyFailedAttempts"];
    const http = flags.find((variant) => [401, 403, 429].includes(info?.[variant]?.httpStatusCode));
    const status = http ? info[http].httpStatusCode : info === "unauthorized" ? 401
      : ["usageLimitExceeded", "rateLimitExceeded"].includes(info) ? 429 : null;
    const message = status === 401 ? "The model service rejected the API credentials."
      : status === 403 ? "The model service denied this request."
      : status === 429 ? "The model service rate or quota limit was reached."
      : diagnostic;
    const codexErrorInfo = http ? { [http]: { httpStatusCode: status } }
      : status === 401 || status === 429 ? info : null;
    return { message, additionalDetails: null, codexErrorInfo };
  };
  if (frame.method === "error" && frame.params?.error) {
    return { ...frame, params: { ...frame.params, error: redact(frame.params.error) } };
  }
  if (frame.method === "turn/completed" && frame.params?.turn?.error) {
    const turn = frame.params.turn;
    return { ...frame, params: { ...frame.params, turn: { ...turn, error: redact(turn.error) } } };
  }
  if (!frame.method && frame.error) {
    return { ...frame, error: { code: Number.isInteger(frame.error.code) ? frame.error.code : -32603, message: diagnostic } };
  }
  return frame;
}

function composeAccountStatus({
  accountRead = null,
  authStatus = null,
  loginInFlight = false,
  bridgeVersionInfo = null,
  allowPackageUpdates = true,
  transportMode = null,
  hostPlatform = process.platform,
} = {}) {
  const account = accountRead?.account || null;
  const authToken = normalizeString(authStatus?.authToken);
  const hasAccountLogin = hasExplicitAccountLogin(account);
  const authMethod = firstNonEmpty([
    normalizeString(authStatus?.authMethod),
    normalizeString(account?.type),
  ]) || null;
  // Voice transcription now uses ChatGPT session auth only; API-key tokens must not advertise voice readiness.
  const tokenReady = Boolean(authToken) && isChatGPTAuthMethod(authMethod);
  const apiKeyConfigured = account?.type === "apiKey" && authMethod === "apiKey";
  const requiresOpenaiAuth = Boolean(accountRead?.requiresOpenaiAuth || authStatus?.requiresOpenaiAuth);
  const hasPriorLoginContext = hasAccountLogin || Boolean(authMethod);
  const needsReauth = !loginInFlight && requiresOpenaiAuth && hasPriorLoginContext && !tokenReady && !apiKeyConfigured;
  const isAuthenticated = !needsReauth && (tokenReady || hasAccountLogin || apiKeyConfigured);
  const status = isAuthenticated
    ? "authenticated"
    : (loginInFlight ? "pending_login" : (needsReauth ? "expired" : "not_logged_in"));

  return {
    status,
    authMethod,
    email: normalizeString(account?.email) || null,
    planType: normalizeString(account?.planType) || null,
    loginInFlight: Boolean(loginInFlight),
    needsReauth,
    tokenReady,
    expiresAt: null,
    requiresOpenaiAuth,
    bridgeVersion: firstNonEmpty([
      normalizeString(bridgeVersionInfo?.bridgeVersion),
      normalizeString(bridgePackageVersion),
    ]) || null,
    bridgeLatestVersion: allowPackageUpdates ? normalizeString(bridgeVersionInfo?.bridgeLatestVersion) || null : null,
    codexTransportMode: normalizeString(transportMode) || null,
    hostPlatform: normalizeHostPlatform(hostPlatform),
    hostCapabilities: deriveHostCapabilities(hostPlatform, allowPackageUpdates),
  };
}

function isChatGPTAuthMethod(authMethod) {
  const normalized = normalizeString(authMethod).toLowerCase().replace(/[^a-z0-9]/g, "");
  return normalized === "chatgpt" || normalized === "chatgptauthtokens";
}

// Removes any token-bearing fields before the bridge sends auth state to the phone.
function redactAuthStatus(authStatus = null, extras = {}) {
  const composed = composeAccountStatus({
    accountRead: extras.accountRead || null,
    authStatus,
    loginInFlight: Boolean(extras.loginInFlight),
    bridgeVersionInfo: extras.bridgeVersionInfo || null,
    allowPackageUpdates: extras.allowPackageUpdates,
    transportMode: extras.transportMode || null,
    hostPlatform: extras.hostPlatform || process.platform,
  });

  return {
    authMethod: composed.authMethod,
    status: composed.status,
    email: composed.email,
    planType: composed.planType,
    loginInFlight: composed.loginInFlight,
    needsReauth: composed.needsReauth,
    tokenReady: composed.tokenReady,
    expiresAt: composed.expiresAt,
    bridgeVersion: composed.bridgeVersion,
    bridgeLatestVersion: composed.bridgeLatestVersion,
    codexTransportMode: composed.codexTransportMode,
    hostPlatform: composed.hostPlatform,
    hostCapabilities: composed.hostCapabilities,
  };
}

// ─── Settled snapshot helpers ───────────────────────────────

// Collapses settled bridge RPC results into one safe snapshot, even if one side fails.
// Input: Promise.allSettled-style results → Output: sanitized account status object
// Throws if both the account read and auth status fail, so the bridge can surface a real error.
function composeSanitizedAuthStatusFromSettledResults({
  accountReadResult = null,
  authStatusResult = null,
  loginInFlight = false,
  bridgeVersionInfo = null,
  allowPackageUpdates = true,
  transportMode = null,
  hostPlatform = process.platform,
} = {}) {
  const accountRead = accountReadResult?.status === "fulfilled" ? accountReadResult.value : null;
  const authStatus = authStatusResult?.status === "fulfilled" ? authStatusResult.value : null;

  if (!accountRead && !authStatus) {
    const error = new Error("Unable to read ChatGPT account status from the bridge.");
    error.errorCode = "auth_status_unavailable";
    throw error;
  }

  return redactAuthStatus(authStatus, {
    accountRead,
    loginInFlight: Boolean(loginInFlight),
    bridgeVersionInfo,
    allowPackageUpdates,
    transportMode,
    hostPlatform,
  });
}

// Treat explicit account signals as authenticated when the token read is temporarily unavailable.
function hasExplicitAccountLogin(account) {
  if (!account || typeof account !== "object") {
    return false;
  }

  if (parseBoolean(account.loggedIn) || parseBoolean(account.logged_in) || parseBoolean(account.isLoggedIn)) {
    return true;
  }

  return Boolean(normalizeString(account.email));
}

// Normalizes empty strings and picks the first meaningful value from a short list.
function firstNonEmpty(values) {
  for (const value of values) {
    const normalized = normalizeString(value);
    if (normalized) {
      return normalized;
    }
  }
  return "";
}

// Keeps auth/account fields compact and consistent in the status snapshot.
function normalizeString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function parseBoolean(value) {
  return value === true;
}

function normalizeHostPlatform(platform) {
  switch (platform) {
    case "darwin":
      return "macos";
    case "linux":
      return "linux";
    case "win32":
      return "windows";
    default:
      return "unknown";
  }
}

function deriveHostCapabilities(platform, allowPackageUpdates) {
  const isMacOS = platform === "darwin";
  return {
    desktopHandoff: isMacOS,
    displayWake: isMacOS,
    keepAwake: isMacOS,
    hostBrowserLogin: isMacOS,
    bridgeUpdate: isMacOS && allowPackageUpdates,
  };
}

module.exports = {
  redactNativeProviderError,
  composeAccountStatus,
  composeSanitizedAuthStatusFromSettledResults,
  redactAuthStatus,
};
