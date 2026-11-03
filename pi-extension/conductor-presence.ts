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
 * Protocol is LF-delimited JSON, mirroring pi's RPC mode (same command names
 * and reply shapes, so conductor's command code works unchanged):
 *   out: agent_start, agent_end, message_update, tool_execution_start/end,
 *        user_message { text }, terminal_prompt_start { kind, title },
 *        terminal_prompt_end, session_replaced, response { id, command, ... }
 *   in:  prompt, abort, get_state, get_session_stats, get_commands,
 *        get_available_models, set_model, get_available_thinking_levels,
 *        set_thinking_level, compact, set_session_name,
 *        get_last_assistant_text, get_fork_messages, new_session, fork, clone
 *
 * Session switches (new/fork/clone) need a command context, so they run
 * through the internal `/conductor-bridge <token>` command. The switch tears
 * this extension instance down: the reply and `session_replaced` go out on
 * `session_shutdown`, and conductor reconnects to the new instance's pipe.
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

/** Thinking levels offered for a reasoning model; pi clamps unsupported ones. */
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

/** Loose view of a session message, enough for stats and text extraction. */
type LooseMessage = {
	role?: string;
	content?: unknown;
	usage?: {
		input?: number;
		output?: number;
		cacheRead?: number;
		cacheWrite?: number;
		totalTokens?: number;
		cost?: { total?: number };
	};
};
type LooseEntry = { type?: string; id?: string; message?: LooseMessage };

type SwitchCommand = "new_session" | "fork" | "clone";
type PendingSwitch = { client: Socket; id: unknown; command: SwitchCommand; token: string; entryId?: string; text?: string };

/**
 * Unique per session instance: a reload or session switch creates a new
 * extension instance (module state may reset), and Windows can hold on to a
 * just-closed pipe name for a moment.
 */
function bridgePath(): string {
	const suffix = `${process.pid}-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
	if (process.platform === "win32") {
		return `\\\\.\\pipe\\conductor-pi-${suffix}`;
	}
	return join(presenceDir, `${suffix}.sock`);
}

/** Plain text of a message's content (string or content blocks). */
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
	let statusBeforePrompt: PresenceStatus | undefined;
	let context: ExtensionContext | undefined;
	let server: Server | undefined;
	let serverPath: string | undefined;
	let listening = false;
	let pendingSwitch: PendingSwitch | undefined;
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
					// Only advertise the pipe once it accepts connections.
					bridge: server && listening ? serverPath : null,
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

	const branchEntries = (ctx: ExtensionContext): LooseEntry[] => ctx.sessionManager.getBranch() as unknown as LooseEntry[];

	const sessionStats = (ctx: ExtensionContext) => {
		const tokens = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 };
		let userMessages = 0;
		let assistantMessages = 0;
		let toolCalls = 0;
		let toolResults = 0;
		let cost = 0;
		for (const entry of branchEntries(ctx)) {
			const message = entry.type === "message" ? entry.message : undefined;
			if (!message) {
				continue;
			}
			if (message.role === "user") {
				userMessages += 1;
			} else if (message.role === "assistant") {
				assistantMessages += 1;
				if (Array.isArray(message.content)) {
					toolCalls += message.content.filter((block) => block && block.type === "toolCall").length;
				}
				const usage = message.usage;
				if (usage) {
					tokens.input += usage.input ?? 0;
					tokens.output += usage.output ?? 0;
					tokens.cacheRead += usage.cacheRead ?? 0;
					tokens.cacheWrite += usage.cacheWrite ?? 0;
					tokens.total += usage.totalTokens ?? 0;
					cost += usage.cost?.total ?? 0;
				}
			} else if (message.role === "toolResult") {
				toolResults += 1;
			}
		}
		return {
			sessionFile: ctx.sessionManager.getSessionFile() ?? null,
			sessionId: ctx.sessionManager.getSessionId(),
			userMessages,
			assistantMessages,
			toolCalls,
			toolResults,
			totalMessages: userMessages + assistantMessages + toolResults,
			tokens,
			cost,
			contextUsage: ctx.getContextUsage() ?? null,
		};
	};

	/** Start a session switch through the internal command (needs a command context). */
	const startSwitch = (client: Socket, id: unknown, command: SwitchCommand, ctx: ExtensionContext, entryId?: string) => {
		if (!ctx.isIdle()) {
			reply(client, id, command, { error: "the agent is busy" });
			return;
		}
		if (pendingSwitch) {
			reply(client, id, command, { error: "another session switch is in progress" });
			return;
		}
		let text: string | undefined;
		if (command === "fork") {
			const entry = entryId ? (ctx.sessionManager.getEntry(entryId) as unknown as LooseEntry | undefined) : undefined;
			if (!entry || entry.message?.role !== "user") {
				reply(client, id, command, { error: "unknown fork entry" });
				return;
			}
			text = messageText(entry.message.content);
		}
		const token = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 10)}`;
		pendingSwitch = { client, id, command, token, entryId, text };
		pi.sendUserMessage(`/conductor-bridge ${token}`, { expandPromptTemplates: true });
	};

	const handleCommand = async (client: Socket, command: Record<string, unknown>) => {
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
						thinkingLevel: pi.getThinkingLevel() ?? null,
						isStreaming: !ctx.isIdle(),
						sessionFile: ctx.sessionManager.getSessionFile() ?? null,
						sessionName: ctx.sessionManager.getSessionName() ?? null,
					},
				});
			} else if (kind === "get_session_stats") {
				reply(client, id, kind, { data: sessionStats(ctx) });
			} else if (kind === "get_commands") {
				const commands = pi
					.getCommands()
					.filter((item) => item.name !== "conductor-bridge")
					.map((item) => ({ name: item.name, description: item.description, source: item.source }));
				reply(client, id, kind, { data: { commands } });
			} else if (kind === "get_available_models") {
				const models = ctx.modelRegistry.getAvailable().map((model) => ({ provider: model.provider, id: model.id, name: model.name }));
				reply(client, id, kind, { data: { models } });
			} else if (kind === "set_model") {
				const model = ctx.modelRegistry.getAvailable().find((candidate) => candidate.provider === command.provider && candidate.id === command.modelId);
				if (!model) {
					reply(client, id, kind, { error: "unknown model" });
					return;
				}
				const ok = await pi.setModel(model);
				reply(client, id, kind, ok ? {} : { error: "no credentials configured for that provider" });
			} else if (kind === "get_available_thinking_levels") {
				reply(client, id, kind, { data: { levels: ctx.model?.reasoning ? THINKING_LEVELS : ["off"] } });
			} else if (kind === "set_thinking_level") {
				if (typeof command.level !== "string" || !THINKING_LEVELS.includes(command.level)) {
					reply(client, id, kind, { error: "unknown thinking level" });
					return;
				}
				pi.setThinkingLevel(command.level as Parameters<typeof pi.setThinkingLevel>[0]);
				reply(client, id, kind, {});
			} else if (kind === "compact") {
				const customInstructions = typeof command.customInstructions === "string" ? command.customInstructions : undefined;
				ctx.compact({
					customInstructions,
					onComplete: (result) =>
						reply(client, id, kind, {
							data: { summary: result.summary, tokensBefore: result.tokensBefore, estimatedTokensAfter: result.estimatedTokensAfter ?? null },
						}),
					onError: (error) => reply(client, id, kind, { error: error.message }),
				});
			} else if (kind === "set_session_name") {
				if (typeof command.name !== "string" || command.name.trim() === "") {
					reply(client, id, kind, { error: "empty name" });
					return;
				}
				pi.setSessionName(command.name);
				write();
				reply(client, id, kind, {});
			} else if (kind === "get_last_assistant_text") {
				const entries = branchEntries(ctx);
				let text: string | null = null;
				for (let index = entries.length - 1; index >= 0 && text === null; index--) {
					const message = entries[index].type === "message" ? entries[index].message : undefined;
					if (message?.role === "assistant") {
						const candidate = messageText(message.content);
						if (candidate !== "") {
							text = candidate;
						}
					}
				}
				reply(client, id, kind, { data: { text } });
			} else if (kind === "get_fork_messages") {
				const messages = branchEntries(ctx)
					.filter((entry) => entry.type === "message" && entry.message?.role === "user" && typeof entry.id === "string")
					.map((entry) => ({ entryId: entry.id, text: messageText(entry.message?.content) }));
				reply(client, id, kind, { data: { messages } });
			} else if (kind === "new_session" || kind === "clone") {
				startSwitch(client, id, kind, ctx);
			} else if (kind === "fork") {
				startSwitch(client, id, kind, ctx, typeof command.entryId === "string" ? command.entryId : undefined);
			} else {
				reply(client, id, kind, { error: "not available for a terminal-attached session" });
			}
		} catch (error) {
			reply(client, id, kind, { error: error instanceof Error ? error.message : String(error) });
		}
	};

	const stopBridge = () => {
		for (const client of clients) {
			// end() flushes pending writes (the switch reply, session_replaced).
			client.end();
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
		listening = false;
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
									handleCommand(client, decoded).catch(() => {});
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
					listening = false;
					write();
				}
			});
			created.listen(path, () => {
				if (server === created) {
					listening = true;
					write();
				}
			});
			server = created;
			serverPath = path;
		} catch {
			server = undefined;
			serverPath = undefined;
			listening = false;
		}
	};

	pi.registerCommand("conductor-bridge", {
		description: "internal (conductor.nvim): session switches requested from the editor",
		handler: async (args, ctx) => {
			const switching = pendingSwitch;
			if (!switching || args.trim() !== switching.token) {
				ctx.ui.notify("/conductor-bridge is used internally by conductor.nvim", "info");
				return;
			}
			const fail = (error: string) => {
				if (pendingSwitch === switching) {
					pendingSwitch = undefined;
					reply(switching.client, switching.id, switching.command, { error });
				}
			};
			try {
				let result: { cancelled: boolean };
				if (switching.command === "new_session") {
					result = await ctx.newSession();
				} else if (switching.command === "fork") {
					result = await ctx.fork(switching.entryId as string);
				} else {
					const leaf = ctx.sessionManager.getLeafId();
					if (!leaf) {
						fail("nothing to clone yet");
						return;
					}
					result = await ctx.fork(leaf, { position: "at" });
				}
				// On success session_shutdown already replied; only a cancel is left.
				if (result.cancelled && pendingSwitch === switching) {
					pendingSwitch = undefined;
					reply(switching.client, switching.id, switching.command, { data: { cancelled: true } });
				}
			} catch (error) {
				fail(error instanceof Error ? error.message : String(error));
			}
		},
	});

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

	// Dialogs can only be answered in the terminal; tell conductor one is open.
	pi.on("ui_prompt_start", async (event) => {
		if (statusBeforePrompt === undefined) {
			statusBeforePrompt = status;
		}
		status = "needs_input";
		write();
		broadcast({ type: "terminal_prompt_start", kind: event.kind, title: event.title ?? null });
	});

	pi.on("ui_prompt_end", async () => {
		if (statusBeforePrompt !== undefined) {
			status = statusBeforePrompt;
			statusBeforePrompt = undefined;
		}
		write();
		broadcast({ type: "terminal_prompt_end" });
	});

	pi.on("session_shutdown", async (event) => {
		const switching = pendingSwitch;
		pendingSwitch = undefined;
		if (switching) {
			reply(switching.client, switching.id, switching.command, { data: { cancelled: false, text: switching.text } });
		}
		// Not quitting: a new extension instance takes over with a new pipe.
		if (event.reason !== "quit") {
			broadcast({ type: "session_replaced" });
		}
		stopBridge();
		context = undefined;
		remove();
	});

	process.on("exit", () => {
		stopBridge();
		remove();
	});
}
