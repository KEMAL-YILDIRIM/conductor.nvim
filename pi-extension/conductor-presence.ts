/**
 * conductor-presence — pi extension that advertises running pi sessions to
 * conductor.nvim and lets conductor drive them live.
 *
 * Presence: writes a small JSON file per pi process into
 * `~/.pi/agent/conductor/presence/<pid>.json`, updated on agent start/end so
 * conductor's sidebar can show external (terminal) sessions and whether they
 * are working or waiting for input. The file is removed on session shutdown.
 *
 * Bridge (terminal sessions only): listens on a local pipe advertised as
 * `bridge` in the presence file. Conductor connects to it instead of spawning
 * a second pi on the same session file, so this process stays the only writer.
 * Protocol is LF-delimited JSON, mirroring pi's RPC mode:
 *   out: agent_start, agent_end, message_update, tool_execution_start/end,
 *        user_message { text }, response { id, command, success, data|error }
 *   in:  prompt { message }, abort, get_state, get_session_stats, get_commands
 *
 * Install: copy this file to ~/.pi/agent/extensions/ (or `pi -e <path>`).
 */
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const presenceDir = join(homedir(), ".pi", "agent", "conductor", "presence");
const presenceFile = join(presenceDir, `${process.pid}.json`);

type PresenceStatus = "idle" | "streaming" | "needs_input";

/** Bumped per session so a new server never collides with one still closing. */
let bridgeCounter = 0;

function bridgePath(): string {
	bridgeCounter += 1;
	if (process.platform === "win32") {
		return `\\\\.\\pipe\\conductor-pi-${process.pid}-${bridgeCounter}`;
	}
	return join(presenceDir, `${process.pid}-${bridgeCounter}.sock`);
}

/** Plain text of a user message's content (string or content blocks). */
function messageText(content: unknown): string {
	if (typeof content === "string") {
		return content;
	}
	if (Array.isArray(content)) {
		return content
			.filter((block) => block && block.type === "text" && typeof block.text === "string")
			.map((block) => block.text as string)
			.join("\n");
	}
	return "";
}

export default function (pi: ExtensionAPI) {
	let status: PresenceStatus = "idle";
	let context: ExtensionContext | undefined;
	let server: Server | undefined;
	let serverPath: string | undefined;
	const clients = new Set<Socket>();

	const write = () => {
		if (!context) {
			return;
		}
		try {
			mkdirSync(presenceDir, { recursive: true });
			writeFileSync(
				presenceFile,
				JSON.stringify({
					pid: process.pid,
					status,
					mode: context.mode,
					bridge: server ? serverPath : null,
					sessionFile: context.sessionManager.getSessionFile() ?? null,
					sessionName: context.sessionManager.getSessionName() ?? null,
					cwd: context.cwd,
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

	/** Send one JSON line to every connected conductor client. */
	const broadcast = (message: unknown) => {
		if (clients.size === 0) {
			return;
		}
		const line = `${JSON.stringify(message)}\n`;
		for (const client of clients) {
			try {
				client.write(line);
			} catch {
				// A broken client is dropped by its own close handler.
			}
		}
	};

	const reply = (client: Socket, id: unknown, command: string, result: { data?: unknown; error?: string }) => {
		const response =
			result.error === undefined
				? { type: "response", id, command, success: true, data: result.data ?? {} }
				: { type: "response", id, command, success: false, error: result.error };
		try {
			client.write(`${JSON.stringify(response)}\n`);
		} catch {
			// ignore
		}
	};

	const handleCommand = (client: Socket, command: Record<string, unknown>) => {
		const kind = typeof command.type === "string" ? command.type : "?";
		const id = command.id;
		const ctx = context;
		if (!ctx) {
			reply(client, id, kind, { error: "session not ready" });
			return;
		}
		try {
			if (kind === "prompt") {
				const message = typeof command.message === "string" ? command.message : "";
				if (message === "") {
					reply(client, id, kind, { error: "empty prompt" });
					return;
				}
				const options: { deliverAs?: "steer"; expandPromptTemplates: boolean } = { expandPromptTemplates: true };
				if (!ctx.isIdle()) {
					options.deliverAs = "steer";
				}
				pi.sendUserMessage(message, options);
				reply(client, id, kind, {});
			} else if (kind === "abort") {
				ctx.abort();
				reply(client, id, kind, {});
			} else if (kind === "get_state") {
				const model = ctx.model;
				reply(client, id, kind, {
					data: {
						model: model ? { provider: model.provider, id: model.id, name: model.name } : null,
						thinkingLevel: ctx.thinkingLevel ?? null,
						isStreaming: !ctx.isIdle(),
						sessionFile: ctx.sessionManager.getSessionFile() ?? null,
						sessionName: ctx.sessionManager.getSessionName() ?? null,
					},
				});
			} else if (kind === "get_session_stats") {
				reply(client, id, kind, { data: { contextUsage: ctx.getContextUsage() ?? null } });
			} else if (kind === "get_commands") {
				const commands = pi.getCommands().map((item) => ({
					name: item.name,
					description: item.description,
					source: item.source,
				}));
				reply(client, id, kind, { data: { commands } });
			} else {
				reply(client, id, kind, { error: "not available for a terminal-attached session" });
			}
		} catch (error) {
			reply(client, id, kind, { error: error instanceof Error ? error.message : String(error) });
		}
	};

	const stopBridge = () => {
		for (const client of clients) {
			client.destroy();
		}
		clients.clear();
		if (server) {
			server.close();
			server = undefined;
		}
		if (serverPath && process.platform !== "win32") {
			rmSync(serverPath, { force: true });
		}
		serverPath = undefined;
	};

	const startBridge = () => {
		stopBridge();
		const path = bridgePath();
		try {
			if (process.platform !== "win32") {
				mkdirSync(presenceDir, { recursive: true });
				rmSync(path, { force: true });
			}
			const created = createServer((client) => {
				clients.add(client);
				client.setEncoding("utf8");
				let buffer = "";
				client.on("data", (chunk: string) => {
					buffer += chunk;
					let newline = buffer.indexOf("\n");
					while (newline >= 0) {
						const line = buffer.slice(0, newline).replace(/\r$/, "");
						buffer = buffer.slice(newline + 1);
						if (line !== "") {
							try {
								const decoded = JSON.parse(line);
								if (decoded && typeof decoded === "object") {
									handleCommand(client, decoded);
								}
							} catch {
								// ignore malformed lines
							}
						}
						newline = buffer.indexOf("\n");
					}
				});
				client.on("close", () => clients.delete(client));
				client.on("error", () => clients.delete(client));
				// A client attaching mid-turn must know the agent is busy.
				if (context && !context.isIdle()) {
					client.write(`${JSON.stringify({ type: "agent_start" })}\n`);
				}
			});
			created.on("error", () => {
				// Bridge is best-effort: drop it and fall back to presence only.
				if (server === created) {
					server = undefined;
					serverPath = undefined;
					write();
				}
			});
			created.listen(path, () => {
				if (server === created) {
					write();
				}
			});
			server = created;
			serverPath = path;
		} catch {
			server = undefined;
			serverPath = undefined;
		}
	};

	pi.on("session_start", async (_event, ctx) => {
		context = ctx;
		status = "idle";
		// Only a terminal pi gets a bridge; conductor's own RPC instances are
		// already driven over stdin/stdout.
		if (ctx.mode === "tui") {
			startBridge();
		}
		write();
	});

	pi.on("agent_start", async (_event, ctx) => {
		context = ctx;
		status = "streaming";
		write();
		broadcast({ type: "agent_start" });
	});

	pi.on("agent_end", async (_event, ctx) => {
		context = ctx;
		status = "needs_input";
		write();
		broadcast({ type: "agent_end" });
	});

	pi.on("message_start", async (event) => {
		const message = event.message as { role?: string; content?: unknown };
		if (message.role === "user") {
			const text = messageText(message.content);
			if (text !== "") {
				broadcast({ type: "user_message", text });
			}
		}
	});

	pi.on("message_update", async (event) => {
		broadcast({ type: "message_update", assistantMessageEvent: event.assistantMessageEvent });
	});

	pi.on("tool_execution_start", async (event) => {
		const args = event.args ?? {};
		broadcast({
			type: "tool_execution_start",
			toolName: event.toolName,
			args: { command: args.command, path: args.path, pattern: args.pattern },
		});
	});

	pi.on("tool_execution_end", async (event) => {
		broadcast({ type: "tool_execution_end", toolName: event.toolName, result: event.result, isError: event.isError });
	});

	pi.on("session_shutdown", async () => {
		stopBridge();
		context = undefined;
		remove();
	});

	process.on("exit", () => {
		stopBridge();
		remove();
	});
}
