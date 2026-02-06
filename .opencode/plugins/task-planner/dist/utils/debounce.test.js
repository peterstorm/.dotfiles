/**
 * Unit tests for debounce.ts
 *
 * Tests the debouncing utilities for phase advancement and message buffering.
 */
import { describe, it, expect, beforeEach } from "vitest";
import { simpleHash, PhaseAdvancementDebouncer, MessageBuffer, } from "./debounce.js";
// ============================================================================
// simpleHash Tests
// ============================================================================
describe("simpleHash", () => {
    it("returns consistent hash for same input", () => {
        const hash1 = simpleHash("test");
        const hash2 = simpleHash("test");
        expect(hash1).toBe(hash2);
    });
    it("returns different hash for different input", () => {
        const hash1 = simpleHash("test1");
        const hash2 = simpleHash("test2");
        expect(hash1).not.toBe(hash2);
    });
    it("returns hex string", () => {
        const hash = simpleHash("test");
        expect(hash).toMatch(/^[0-9a-f]+$/);
    });
    it("handles empty string", () => {
        const hash = simpleHash("");
        expect(hash).toBeTruthy();
    });
    it("handles long strings", () => {
        const longString = "a".repeat(10000);
        const hash = simpleHash(longString);
        expect(hash).toBeTruthy();
        expect(hash.length).toBeLessThan(20);
    });
    it("handles unicode", () => {
        const hash = simpleHash("Hello, world!");
        expect(hash).toBeTruthy();
    });
});
// ============================================================================
// PhaseAdvancementDebouncer Tests
// ============================================================================
describe("PhaseAdvancementDebouncer", () => {
    let debouncer;
    beforeEach(() => {
        debouncer = new PhaseAdvancementDebouncer(100); // 100ms for tests
    });
    describe("shouldProcess", () => {
        it("returns true for first call", () => {
            expect(debouncer.shouldProcess("content")).toBe(true);
        });
        it("returns false for same content immediately after", () => {
            debouncer.shouldProcess("content");
            expect(debouncer.shouldProcess("content")).toBe(false);
        });
        it("returns false for different content within debounce window", () => {
            // Note: Even different content is rejected within debounce window
            // This is rate limiting, not just deduplication
            debouncer.shouldProcess("content1");
            expect(debouncer.shouldProcess("content2")).toBe(false);
        });
        it("returns false within debounce window even with different content", async () => {
            debouncer.shouldProcess("content1");
            // Don't wait - call immediately
            expect(debouncer.shouldProcess("content2")).toBe(false);
        });
        it("returns true after debounce window expires", async () => {
            debouncer.shouldProcess("content1");
            // Wait for debounce window
            await new Promise((resolve) => setTimeout(resolve, 150));
            expect(debouncer.shouldProcess("content2")).toBe(true);
        });
    });
    describe("markProcessed", () => {
        it("updates timestamp", async () => {
            debouncer.shouldProcess("content");
            // Wait a bit
            await new Promise((resolve) => setTimeout(resolve, 50));
            debouncer.markProcessed();
            // Still within debounce window after markProcessed
            expect(debouncer.isWithinDebounceWindow()).toBe(true);
        });
    });
    describe("reset", () => {
        it("clears state allowing reprocessing", () => {
            debouncer.shouldProcess("content");
            expect(debouncer.shouldProcess("content")).toBe(false);
            debouncer.reset();
            expect(debouncer.shouldProcess("content")).toBe(true);
        });
    });
    describe("getDebounceMs", () => {
        it("returns configured debounce time", () => {
            expect(debouncer.getDebounceMs()).toBe(100);
        });
        it("uses default if not specified", () => {
            const defaultDebouncer = new PhaseAdvancementDebouncer();
            expect(defaultDebouncer.getDebounceMs()).toBeGreaterThan(0);
        });
    });
    describe("isWithinDebounceWindow", () => {
        it("returns false before first call", () => {
            expect(debouncer.isWithinDebounceWindow()).toBe(false);
        });
        it("returns true immediately after shouldProcess", () => {
            debouncer.shouldProcess("content");
            expect(debouncer.isWithinDebounceWindow()).toBe(true);
        });
        it("returns false after debounce window", async () => {
            debouncer.shouldProcess("content");
            await new Promise((resolve) => setTimeout(resolve, 150));
            expect(debouncer.isWithinDebounceWindow()).toBe(false);
        });
    });
});
// ============================================================================
// MessageBuffer Tests
// ============================================================================
describe("MessageBuffer", () => {
    let buffer;
    beforeEach(() => {
        buffer = new MessageBuffer(5);
    });
    describe("push", () => {
        it("adds message to buffer", () => {
            buffer.push("user", "Hello");
            expect(buffer.size()).toBe(1);
        });
        it("maintains max size", () => {
            for (let i = 0; i < 10; i++) {
                buffer.push("user", `Message ${i}`);
            }
            expect(buffer.size()).toBe(5);
        });
        it("removes oldest message when full", () => {
            for (let i = 0; i < 10; i++) {
                buffer.push("user", `Message ${i}`);
            }
            const messages = buffer.getAllMessages();
            expect(messages[0]?.content).toBe("Message 5");
            expect(messages[4]?.content).toBe("Message 9");
        });
    });
    describe("getLastByRole", () => {
        it("returns null for empty buffer", () => {
            expect(buffer.getLastByRole("assistant")).toBeNull();
        });
        it("returns last message for role", () => {
            buffer.push("user", "User 1");
            buffer.push("assistant", "Assistant 1");
            buffer.push("user", "User 2");
            buffer.push("assistant", "Assistant 2");
            expect(buffer.getLastByRole("assistant")).toBe("Assistant 2");
            expect(buffer.getLastByRole("user")).toBe("User 2");
        });
        it("returns null if role not found", () => {
            buffer.push("user", "Hello");
            expect(buffer.getLastByRole("system")).toBeNull();
        });
    });
    describe("getLastAssistantMessage", () => {
        it("returns last assistant message", () => {
            buffer.push("assistant", "Response 1");
            buffer.push("assistant", "Response 2");
            expect(buffer.getLastAssistantMessage()).toBe("Response 2");
        });
        it("returns null when no assistant messages", () => {
            buffer.push("user", "Hello");
            expect(buffer.getLastAssistantMessage()).toBeNull();
        });
    });
    describe("clear", () => {
        it("removes all messages", () => {
            buffer.push("user", "Hello");
            buffer.push("assistant", "Hi");
            buffer.clear();
            expect(buffer.size()).toBe(0);
        });
    });
    describe("size", () => {
        it("returns 0 for empty buffer", () => {
            expect(buffer.size()).toBe(0);
        });
        it("returns correct count", () => {
            buffer.push("user", "1");
            buffer.push("user", "2");
            buffer.push("user", "3");
            expect(buffer.size()).toBe(3);
        });
    });
    describe("getFullTranscript", () => {
        it("returns empty string for empty buffer", () => {
            expect(buffer.getFullTranscript()).toBe("");
        });
        it("formats messages with role prefixes", () => {
            buffer.push("user", "Hello");
            buffer.push("assistant", "Hi there");
            const transcript = buffer.getFullTranscript();
            expect(transcript).toContain("[user]: Hello");
            expect(transcript).toContain("[assistant]: Hi there");
        });
        it("separates messages with double newlines", () => {
            buffer.push("user", "A");
            buffer.push("assistant", "B");
            const transcript = buffer.getFullTranscript();
            expect(transcript).toContain("\n\n");
        });
    });
    describe("getAllMessages", () => {
        it("returns empty array for empty buffer", () => {
            expect(buffer.getAllMessages()).toEqual([]);
        });
        it("returns copies without timestamps", () => {
            buffer.push("user", "Hello");
            const messages = buffer.getAllMessages();
            expect(messages).toEqual([{ role: "user", content: "Hello" }]);
            expect(messages[0].timestamp).toBeUndefined();
        });
        it("returns messages in order", () => {
            buffer.push("user", "1");
            buffer.push("assistant", "2");
            buffer.push("user", "3");
            const messages = buffer.getAllMessages();
            expect(messages.map((m) => m.content)).toEqual(["1", "2", "3"]);
        });
    });
    describe("custom max size", () => {
        it("respects custom max size", () => {
            const smallBuffer = new MessageBuffer(2);
            smallBuffer.push("user", "1");
            smallBuffer.push("user", "2");
            smallBuffer.push("user", "3");
            expect(smallBuffer.size()).toBe(2);
            expect(smallBuffer.getAllMessages()[0]?.content).toBe("2");
        });
    });
});
//# sourceMappingURL=debounce.test.js.map