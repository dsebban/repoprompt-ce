import type { AssistantMessage, Usage } from "@earendil-works/pi-ai";
import type { AgentEvent, EntryRecord, SubmissionId, UsageState } from "@earendil-works/pi-durable";
import { toolKind } from "./approvals.ts";

/** One ACP `session/update` payload (the `update` object). */
export type SessionUpdate = Record<string, unknown> & { sessionUpdate: string };

export interface TranslatorHooks {
	/** Maps pi submission ids back to the client's request ids (plan §3.3 "Run ids"). */
	requestIdFor(submission: SubmissionId): string | undefined;
	/** The current model's context window, for `usage_update.size`. */
	contextWindow(): number | undefined;
}

/**
 * Translates pi-durable agent events (one batch per commit) into ACP `session/update`s (plan §3.3):
 * message deltas become `agent_message_chunk` / `agent_thought_chunk`, tool executions become
 * `tool_call` / `tool_call_update`, usage becomes `usage_update`, compaction becomes
 * `session_info_update`, and run boundaries become `_pi/run_start` / `_pi/run_end`. Every update carries
 * `_meta.pi = {entryId?, headEntryId, runId?}`.
 */
export class EventTranslator {
	readonly #hooks: TranslatorHooks;
	#headEntryId: string | undefined;
	#runId: string | undefined;
	#messageSeq = 0;
	#messageId: string | undefined;
	#streamedText = "";
	#streamedThinking = "";
	#lastUsed: number | undefined;
	#lastCost: number | undefined;
	readonly #requestIdBySubmission = new Map<SubmissionId, string>();
	readonly #toolNames = new Map<string, string>();
	readonly #toolArgs = new Map<string, unknown>();

	constructor(hooks: TranslatorHooks) {
		this.#hooks = hooks;
	}

	get runId(): string | undefined {
		return this.#runId;
	}

	translate(events: readonly AgentEvent[]): SessionUpdate[] {
		const updates: SessionUpdate[] = [];
		for (const event of events) updates.push(...this.#translateOne(event));
		return updates;
	}

	/** ACP forbids custom root fields on spec types, so pi's own data (tool names included) rides `_meta.pi`. */
	#meta(entryId?: string, toolName?: string): Record<string, unknown> {
		return {
			pi: {
				...(entryId === undefined ? {} : { entryId }),
				...(toolName === undefined ? {} : { toolName }),
				...(this.#headEntryId === undefined ? {} : { headEntryId: this.#headEntryId }),
				...(this.#runId === undefined ? {} : { runId: this.#runId }),
			},
		};
	}

	#translateOne(event: AgentEvent): SessionUpdate[] {
		switch (event.type) {
			case "snapshot": {
				// The head marker heads `entries`; it changes on compaction or reset.
				this.#headEntryId = idOf(event.entries[0]?.id);
				this.#runId = idOf(event.run?.inputs[0]);
				for (const tool of event.tools) this.#toolNames.set(tool.callId, tool.name);
				return [];
			}
			case "run_start": {
				this.#runId = idOf(event.inputs[0]);
				return [
					{
						sessionUpdate: "_pi/run_start",
						runId: this.#runId,
						requestIds: this.#requestIds(event.inputs),
						_meta: this.#meta(),
					},
				];
			}
			case "run_end": {
				const update: SessionUpdate = {
					sessionUpdate: "_pi/run_end",
					runId: idOf(event.inputs[0]) ?? this.#runId,
					requestIds: this.#requestIds(event.inputs),
					_meta: this.#meta(),
				};
				this.#runId = undefined;
				return [update];
			}
			case "message_start": {
				if (event.message.role === "assistant") this.#messageId = `m${++this.#messageSeq}`;
				this.#streamedText = "";
				this.#streamedThinking = "";
				return [];
			}
			case "message_update": {
				const updates: SessionUpdate[] = [];
				for (const change of event.changes) {
					if (change.type === "text_delta" && change.delta.length > 0) {
						this.#streamedText += change.delta;
						updates.push({
							sessionUpdate: "agent_message_chunk",
							content: { type: "text", text: change.delta },
							...(this.#messageId === undefined ? {} : { messageId: this.#messageId }),
							_meta: this.#meta(),
						});
					} else if (change.type === "thinking_delta" && change.delta.length > 0) {
						this.#streamedThinking += change.delta;
						updates.push({
							sessionUpdate: "agent_thought_chunk",
							content: { type: "text", text: change.delta },
							_meta: this.#meta(),
						});
					}
				}
				return updates;
			}
			case "message_end": {
				const message = event.entry.model?.[0];
				const messageId = this.#messageId;
				this.#messageId = undefined;
				if (message?.role !== "assistant") return [];
				const assistant = message as AssistantMessage;
				const updates: SessionUpdate[] = [];
				// A message committed whole (or partly streamed before a restart) sends what was not streamed yet.
				const thinking = assistant.content
					.flatMap((block) => (block.type === "thinking" ? [block.thinking] : []))
					.join("");
				const thinkingRest = remainder(thinking, this.#streamedThinking);
				if (thinkingRest.length > 0) {
					updates.push({
						sessionUpdate: "agent_thought_chunk",
						content: { type: "text", text: thinkingRest },
						_meta: this.#meta(idOf(event.entry.id)),
					});
				}
				const text = assistant.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");
				const textRest = remainder(text, this.#streamedText);
				if (textRest.length > 0) {
					updates.push({
						sessionUpdate: "agent_message_chunk",
						content: { type: "text", text: textRest },
						...(messageId === undefined ? {} : { messageId }),
						_meta: this.#meta(idOf(event.entry.id)),
					});
				}
				this.#streamedText = "";
				this.#streamedThinking = "";
				this.#lastUsed = contextTokens(assistant.usage);
				updates.push(this.#usageUpdate(idOf(event.entry.id)));
				return updates;
			}
			case "tool_execution_start": {
				this.#toolNames.set(event.toolCallId, event.toolName);
				this.#toolArgs.set(event.toolCallId, event.args);
				return [
					{
						sessionUpdate: "tool_call",
						toolCallId: event.toolCallId,
						title: toolTitle(event.toolName, event.args),
						kind: toolKind(event.toolName),
						status: "in_progress",
						rawInput: event.args,
						_meta: this.#meta(undefined, event.toolName),
					},
				];
			}
			case "tool_execution_update":
				// Output streams are committed every 100 ms; the final result carries the retained output, so
				// intermediate output is not re-sent (each ACP update would replace the whole content).
				return [];
			case "tool_execution_end": {
				const toolName = this.#toolNames.get(event.toolCallId) ?? event.toolName;
				const rawInput = this.#toolArgs.get(event.toolCallId);
				this.#toolNames.delete(event.toolCallId);
				this.#toolArgs.delete(event.toolCallId);
				const result = toolResult(event.entry);
				return [
					{
						sessionUpdate: "tool_call_update",
						toolCallId: event.toolCallId,
						status: result.isError ? "failed" : "completed",
						...(rawInput === undefined ? {} : { rawInput }),
						rawOutput: { output: result.text, isError: result.isError },
						content: [{ type: "content", content: { type: "text", text: result.text } }],
						_meta: this.#meta(idOf(event.entry?.id), toolName),
					},
				];
			}
			case "usage_changed": {
				this.#lastCost = totalCost(event.usage);
				return [this.#usageUpdate()];
			}
			case "submission": {
				// Submissions carry the client's request id; they are committed with (before) their run's start.
				if (event.record.requestId !== undefined)
					this.#requestIdBySubmission.set(event.record.id, event.record.requestId);
				return [];
			}
			case "entry_appended": {
				if (event.entry.kind === "pi.compaction" || event.entry.kind === "pi.reset")
					this.#headEntryId = idOf(event.entry.id);
				return [];
			}
			case "compaction_start":
				return [{ sessionUpdate: "session_info_update", title: "Compacting context…", _meta: this.#meta() }];
			case "compaction_end":
				return [{ sessionUpdate: "session_info_update", title: "Context compacted", _meta: this.#meta() }];
			case "auto_retry_start":
				return [
					{
						sessionUpdate: "session_info_update",
						title: `Retrying model request (attempt ${event.attempt}): ${event.errorMessage}`,
						_meta: this.#meta(),
					},
				];
			default:
				return [];
		}
	}

	#requestIds(inputs: readonly SubmissionId[]): string[] {
		return inputs.flatMap((input) => {
			const requestId = this.#requestIdBySubmission.get(input) ?? this.#hooks.requestIdFor(input);
			return requestId === undefined ? [] : [requestId];
		});
	}

	#usageUpdate(entryId?: string): SessionUpdate {
		const size = this.#hooks.contextWindow();
		return {
			sessionUpdate: "usage_update",
			...(this.#lastUsed === undefined ? {} : { used: this.#lastUsed }),
			...(size === undefined ? {} : { size }),
			...(this.#lastCost === undefined ? {} : { cost: { amount: this.#lastCost, currency: "USD" } }),
			_meta: this.#meta(entryId),
		};
	}
}

/** pi ids are ordered branded numbers; they travel as decimal strings on the wire. */
function idOf(id: number | undefined): string | undefined {
	return id === undefined ? undefined : String(id);
}

/** The part of `full` not yet sent as `streamed`; everything when they diverged. */
function remainder(full: string, streamed: string): string {
	if (streamed.length === 0) return full;
	return full.startsWith(streamed) ? full.slice(streamed.length) : "";
}

/** Tokens the last request put in the context window. */
function contextTokens(usage: Usage | undefined): number | undefined {
	if (usage === undefined) return undefined;
	return usage.input + usage.cacheRead + usage.cacheWrite + usage.output;
}

function totalCost(usage: UsageState): number {
	let total = 0;
	for (const bucket of [...Object.values(usage.models), ...Object.values(usage.tools)]) {
		total += (bucket as { cost?: { total?: number } }).cost?.total ?? 0;
	}
	return total;
}

function toolResult(entry: EntryRecord | undefined): { text: string; isError: boolean } {
	const message = entry?.model?.[0] as { content?: unknown; isError?: boolean } | undefined;
	if (message === undefined) return { text: "Tool did not complete.", isError: true };
	const content = message.content;
	const text = Array.isArray(content)
		? content
				.flatMap((block: { type?: string; text?: string }) =>
					block.type === "text" && typeof block.text === "string" ? [block.text] : [],
				)
				.join("\n")
		: typeof content === "string"
			? content
			: "";
	return { text, isError: message.isError === true };
}

export function toolTitle(toolName: string, args: unknown): string {
	const record = (args ?? {}) as Record<string, unknown>;
	const detail = toolName === "bash" ? record.command : (record.path ?? record.file_path);
	return typeof detail === "string" && detail.length > 0 ? `${toolName}: ${detail}` : toolName;
}
