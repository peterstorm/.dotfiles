/**
 * Task Planner Plugin - Debounce Utilities
 *
 * Provides debouncing for session.idle and message.updated events
 * to prevent rapid re-triggering of phase advancement checks.
 */
import { PHASE_ADVANCEMENT_DEBOUNCE_MS } from "../constants.js";
// ============================================================================
// Hash Function
// ============================================================================
/**
 * Simple hash function for content deduplication.
 *
 * Uses djb2 algorithm - fast and sufficient for content comparison.
 * Not cryptographically secure, but that's not needed here.
 *
 * @param str - String to hash
 * @returns Hash as a hex string
 */
export function simpleHash(str) {
    let hash = 5381;
    for (let i = 0; i < str.length; i++) {
        // hash * 33 + char
        hash = (hash << 5) + hash + str.charCodeAt(i);
        // Keep as 32-bit integer
        hash = hash >>> 0;
    }
    return hash.toString(16);
}
// ============================================================================
// Phase Advancement Debouncer
// ============================================================================
/**
 * Manages debouncing for session.idle phase advancement checks.
 *
 * Prevents rapid re-triggering when:
 * 1. Multiple idle events fire in quick succession
 * 2. The same message content is processed multiple times
 *
 * Usage:
 * ```typescript
 * const debouncer = new PhaseAdvancementDebouncer();
 *
 * // In session.idle handler:
 * if (!debouncer.shouldProcess(lastMessageContent)) {
 *   return; // Skip duplicate processing
 * }
 *
 * // Process phase advancement...
 *
 * debouncer.markProcessed();
 * ```
 */
export class PhaseAdvancementDebouncer {
    /** Timestamp of last processed check */
    lastCheckTimestamp = 0;
    /** Hash of last processed content */
    lastContentHash = "";
    /** Debounce interval in milliseconds */
    debounceMs;
    /**
     * Create a new debouncer.
     *
     * @param debounceMs - Debounce interval (default from constants)
     */
    constructor(debounceMs) {
        this.debounceMs = debounceMs ?? PHASE_ADVANCEMENT_DEBOUNCE_MS;
    }
    /**
     * Check if we should process this idle/message event.
     *
     * Returns false if:
     * - Same content was already processed (deduplication)
     * - Within debounce window of last check (rate limiting)
     *
     * @param content - Message content to check (for deduplication)
     * @returns true if processing should proceed
     */
    shouldProcess(content) {
        const now = Date.now();
        const contentHash = simpleHash(content);
        // Skip if same content already processed
        if (contentHash === this.lastContentHash) {
            return false;
        }
        // Skip if within debounce window
        if (now - this.lastCheckTimestamp < this.debounceMs) {
            return false;
        }
        // Update state for next check
        this.lastCheckTimestamp = now;
        this.lastContentHash = contentHash;
        return true;
    }
    /**
     * Mark that processing completed successfully.
     *
     * Call this after successful phase advancement to update
     * the timestamp for debouncing.
     */
    markProcessed() {
        this.lastCheckTimestamp = Date.now();
    }
    /**
     * Reset the debouncer state.
     *
     * Useful when starting a new session or after significant
     * state changes that require re-checking.
     */
    reset() {
        this.lastCheckTimestamp = 0;
        this.lastContentHash = "";
    }
    /**
     * Get the debounce interval in milliseconds.
     */
    getDebounceMs() {
        return this.debounceMs;
    }
    /**
     * Check if currently within debounce window.
     *
     * Useful for debugging and testing.
     */
    isWithinDebounceWindow() {
        return Date.now() - this.lastCheckTimestamp < this.debounceMs;
    }
}
// ============================================================================
// Message Buffer for session.idle
// ============================================================================
/**
 * Circular buffer for tracking recent messages.
 *
 * Used to retrieve the last assistant message in session.idle
 * handlers, since OpenCode may not provide message history directly.
 */
export class MessageBuffer {
    /** Maximum number of messages to retain */
    maxSize;
    /** Buffer of recent messages */
    messages = [];
    /**
     * Create a new message buffer.
     *
     * @param maxSize - Maximum messages to retain (default: 10)
     */
    constructor(maxSize = 10) {
        this.maxSize = maxSize;
    }
    /**
     * Add a message to the buffer.
     *
     * @param role - Message role (user, assistant, system)
     * @param content - Message content
     */
    push(role, content) {
        this.messages.push({
            role,
            content,
            timestamp: Date.now(),
        });
        // Trim to max size
        if (this.messages.length > this.maxSize) {
            this.messages.shift();
        }
    }
    /**
     * Get the last message with the specified role.
     *
     * @param role - Role to filter by (e.g., "assistant")
     * @returns The last message content, or null if none found
     */
    getLastByRole(role) {
        for (let i = this.messages.length - 1; i >= 0; i--) {
            const message = this.messages[i];
            if (message && message.role === role) {
                return message.content;
            }
        }
        return null;
    }
    /**
     * Get the last assistant message.
     *
     * Convenience method for the common case.
     */
    getLastAssistantMessage() {
        return this.getLastByRole("assistant");
    }
    /**
     * Clear all messages from the buffer.
     */
    clear() {
        this.messages = [];
    }
    /**
     * Get the number of messages in the buffer.
     */
    size() {
        return this.messages.length;
    }
    /**
     * Get the full transcript of all buffered messages.
     *
     * Returns all messages concatenated with role prefixes,
     * useful for providing context on task completion.
     *
     * Format:
     * ```
     * [user]: message content
     * [assistant]: response content
     * ```
     */
    getFullTranscript() {
        return this.messages
            .map((m) => `[${m.role}]: ${m.content}`)
            .join("\n\n");
    }
    /**
     * Get all messages in the buffer.
     *
     * Returns a copy of the messages array (without timestamps).
     */
    getAllMessages() {
        return this.messages.map((m) => ({ role: m.role, content: m.content }));
    }
}
//# sourceMappingURL=debounce.js.map