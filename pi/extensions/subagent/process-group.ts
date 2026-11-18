import type { ChildProcess } from "node:child_process";

/** Grace between SIGTERM and SIGKILL when a call is cancelled. */
export const GROUP_KILL_GRACE_MS = 5_000;

/**
 * Children are spawned detached so each one leads its own process group; aborting a call can then kill
 * the tree the child spawned (a reviewer's own `bash` tool included), not just the direct pid.
 * Windows has no process groups with this shape, so it keeps the default spawn mode and a direct kill.
 */
export function spawnDetachedOptions(): { detached: boolean } {
	return process.platform === "win32" ? { detached: false } : { detached: true };
}

export function killProcessGroup(
	proc: Pick<ChildProcess, "pid" | "kill">,
	signal: NodeJS.Signals,
): void {
	if (process.platform !== "win32" && typeof proc.pid === "number") {
		try {
			process.kill(-proc.pid, signal);
			return;
		} catch {
			// The group is already gone, or the child never entered its own group (spawn failure):
			// fall back to the direct pid so a live child is still signalled.
		}
	}
	proc.kill(signal);
}
