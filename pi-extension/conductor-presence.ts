/**
 * conductor-presence — pi extension that advertises running pi sessions to
 * conductor.nvim.
 *
 * Writes a small JSON presence file per pi process into
 * `~/.pi/agent/conductor/presence/<pid>.json`, updated on agent start/end so
 * conductor's sidebar can show external (terminal) sessions and whether they
 * are working or waiting for input. The file is removed on session shutdown.
 *
 * Install: copy this file to ~/.pi/agent/extensions/ (or `pi -e <path>`).
 */
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const presenceDir = join(homedir(), ".pi", "agent", "conductor", "presence");
const presenceFile = join(presenceDir, `${process.pid}.json`);

type PresenceStatus = "idle" | "streaming" | "needs_input";

export default function (pi: ExtensionAPI) {
	let status: PresenceStatus = "idle";

	const write = (ctx: { sessionManager: { getSessionFile(): string | undefined; getSessionName(): string | undefined }; cwd: string }) => {
		try {
			mkdirSync(presenceDir, { recursive: true });
			writeFileSync(
				presenceFile,
				JSON.stringify({
					pid: process.pid,
					status,
					sessionFile: ctx.sessionManager.getSessionFile() ?? null,
					sessionName: ctx.sessionManager.getSessionName() ?? null,
					cwd: ctx.cwd,
					updatedAt: new Date().toISOString(),
				}),
			);
		} catch {
			// Presence is best-effort; never break the agent over it.
		}
	};

	const remove = () => {
		try {
			rmSync(presenceFile, { force: true });
		} catch {
			// ignore
		}
	};

	pi.on("session_start", async (_event, ctx) => {
		status = "idle";
		write(ctx);
	});

	pi.on("agent_start", async (_event, ctx) => {
		status = "streaming";
		write(ctx);
	});

	pi.on("agent_end", async (_event, ctx) => {
		status = "needs_input";
		write(ctx);
	});

	pi.on("session_shutdown", async () => {
		remove();
	});

	process.on("exit", remove);
}
