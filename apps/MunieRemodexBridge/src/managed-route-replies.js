const { randomUUID } = require("node:crypto");

const MAX_PENDING_REPLIES = 500;
const ROUTED_ID_PREFIX = "munie-managed-route:";

function isManagedRouteRequestId(id) {
  return typeof id === "string" && id.startsWith(ROUTED_ID_PREFIX);
}

// Retire correlated replies on route changes independently of event replay.
function createManagedRouteReplies() {
  const pending = new Map();

  return {
    clear() { pending.clear(); },
    wrapRequest(message) {
      if (pending.size >= MAX_PENDING_REPLIES) return null;
      const id = `${ROUTED_ID_PREFIX}${randomUUID()}`;
      pending.set(id, message.id);
      return { ...message, id };
    },
    takeReply(message) {
      if (!isManagedRouteRequestId(message.id) || !pending.has(message.id)) return null;
      const id = pending.get(message.id);
      pending.delete(message.id);
      return { ...message, id };
    },
  };
}

module.exports = { createManagedRouteReplies, isManagedRouteRequestId };
