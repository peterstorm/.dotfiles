/**
 * Task Planner Plugin - Debounce Utilities
 *
 * Provides debouncing for session.idle and message.updated events
 * to prevent rapid re-triggering of phase advancement checks.
 */
/**
 * Simple hash function for content deduplication.
 *
 * Uses djb2 algorithm - fast and sufficient for content comparison.
 * Not cryptographically secure, but that's not needed here.
 *
 * @param str - String to hash
 * @returns Hash as a hex string
 */
export declare function simpleHash(str: string): string;
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
export declare class PhaseAdvancementDebouncer {
    /** Timestamp of last processed check */
    private lastCheckTimestamp;
    /** Hash of last processed content */
    private lastContentHash;
    /** Debounce interval in milliseconds */
    private readonly debounceMs;
    /**
     * Create a new debouncer.
     *
     * @param debounceMs - Debounce interval (default from constants)
     */
    constructor(debounceMs?: number);
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
    shouldProcess(content: string): boolean;
    /**
     * Mark that processing completed successfully.
     *
     * Call this after successful phase advancement to update
     * the timestamp for debouncing.
     */
    markProcessed(): void;
    /**
     * Reset the debouncer state.
     *
     * Useful when starting a new session or after significant
     * state changes that require re-checking.
     */
    reset(): void;
    /**
     * Get the debounce interval in milliseconds.
     */
    getDebounceMs(): number;
    /**
     * Check if currently within debounce window.
     *
     * Useful for debugging and testing.
     */
    isWithinDebounceWindow(): boolean;
}
/**
 * Circular buffer for tracking recent messages.
 *
 * Used to retrieve the last assistant message in session.idle
 * handlers, since OpenCode may not provide message history directly.
 */
export declare class MessageBuffer {
    /** Maximum number of messages to retain */
    private readonly maxSize;
    /** Buffer of recent messages */
    private messages;
    /**
     * Create a new message buffer.
     *
     * @param maxSize - Maximum messages to retain (default: 10)
     */
    constructor(maxSize?: number);
    /**
     * Add a message to the buffer.
     *
     * @param role - Message role (user, assistant, system)
     * @param content - Message content
     */
    push(role: string, content: string): void;
    /**
     * Get the last message with the specified role.
     *
     * @param role - Role to filter by (e.g., "assistant")
     * @returns The last message content, or null if none found
     */
    getLastByRole(role: string): string | null;
    /**
     * Get the last assistant message.
     *
     * Convenience method for the common case.
     */
    getLastAssistantMessage(): string | null;
    /**
     * Clear all messages from the buffer.
     */
    clear(): void;
    /**
     * Get the number of messages in the buffer.
     */
    size(): number;
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
    getFullTranscript(): string;
    /**
     * Get all messages in the buffer.
     *
     * Returns a copy of the messages array (without timestamps).
     */
    getAllMessages(): Array<{
        role: string;
        content: string;
    }>;
}
//# sourceMappingURL=debounce.d.ts.map