import type { Context } from "@earendil-works/chord";
import type { ToolCall } from "@earendil-works/pi-ai";
import { type ConversationId, defineDoc, defineExtension, hook, ToolTask } from "@earendil-works/pi-durable";

/** RepoPrompt permission levels, advertised as the ACP `mode` config option (plan §7.2). */
export type PermissionMode = "ask" | "auto-edit" | "full-access";

export const PERMISSION_MODES: readonly {
	readonly value: PermissionMode;
	readonly name: string;
	readonly description: string;
}[] = [
	{ value: "ask", name: "Ask", description: "Ask before writing or editing files and before running commands." },
	{ value: "auto-edit", name: "Auto Edit", description: "Write and edit files freely; ask before running commands." },
	{ value: "full-access", name: "Full Access", description: "Run every tool without asking." },
];

export function isPermissionMode(value: unknown): value is PermissionMode {
	return PERMISSION_MODES.some((mode) => mode.value === value);
}

/** The session's current mode. Stored so a resumed run uses the last mode set (plan §7.2). */
export const PermissionDoc = defineDoc<{ mode: PermissionMode }>({
	kind: "app.rp-permission",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "current",
	initial: () => ({ mode: "ask" }),
});

/** Tools the user allowed for the rest of the session with an explicit "accept for session" (plan §7.3). */
export const ApprovalRulesDoc = defineDoc<{ tools: string[] }>({
	kind: "app.rp-approval-rules",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({ tools: [] }),
});

const READ_ONLY_TOOLS = new Set(["read"]);
const EDIT_TOOLS = new Set(["write", "edit"]);

/** Ask: everything except `read`. Auto Edit: everything except `read`, `write`, `edit`. Full Access: nothing. */
export function requiresApproval(mode: PermissionMode, toolName: string): boolean {
	if (READ_ONLY_TOOLS.has(toolName)) return false;
	switch (mode) {
		case "full-access":
			return false;
		case "auto-edit":
			return !EDIT_TOOLS.has(toolName);
		case "ask":
			return true;
	}
}

/** ACP `toolCall.kind` for a pi tool. */
export function toolKind(toolName: string): "read" | "edit" | "execute" | "other" {
	if (READ_ONLY_TOOLS.has(toolName)) return "read";
	if (EDIT_TOOLS.has(toolName)) return "edit";
	if (toolName === "bash") return "execute";
	return "other";
}

/**
 * A client decision. Only a `selected` outcome is memoized; `cancelled` resolves the call as blocked
 * without recording a decision that would survive the task.
 */
export type ApprovalDecision =
	| { readonly kind: "allow"; readonly rememberForSession: boolean }
	| { readonly kind: "reject"; readonly reason: string }
	| { readonly kind: "cancelled"; readonly reason: string };

/** Routes approval requests to the attached client (child mode: always the parent RepoPrompt). */
export interface ApprovalBroker {
	request(conversationId: ConversationId, call: ToolCall, context: Context): Promise<ApprovalDecision>;
	/** Commits a session rule; runs outside the hook, which has no commit access. */
	rememberTool(conversationId: ConversationId, toolName: string): Promise<void>;
}

type MemoDecision = "allow" | { readonly block: string };

/**
 * `beforeTool` runs before the tool's intent is committed, and recovery never reruns it once intent
 * is committed, so a decision is asked at most once per call (plan §7.3). A crash before intent
 * reruns the hook: in child mode the interrupted run is abandoned, so nothing is re-asked.
 *
 * Phase 0 finding: `HookApi` offers committed reads and memos but no commit, so the session rule and
 * the permission mode are committed by the binary outside the hook.
 */
export function createApprovalExtension(broker: ApprovalBroker) {
	return defineExtension({
		name: "rp-approvals",
		hooks: [
			hook(ToolTask, {
				beforeTool: async (call, api, context) => {
					const permission = await api.snapshot(PermissionDoc, api.conversationId, context);
					const mode = permission?.mode ?? "ask";
					if (!requiresApproval(mode, call.name)) return undefined;
					const rules = await api.snapshot(ApprovalRulesDoc, api.conversationId, context);
					if (rules?.tools.includes(call.name) === true) return undefined;

					const memoName = `approval:${call.id}`;
					const existing = await api.memo<MemoDecision>(memoName, context);
					if (existing !== undefined) return apply(existing);

					const decision = await broker.request(api.conversationId, call, context);
					if (decision.kind === "cancelled") return { block: decision.reason };
					// First writer wins: a concurrent decision for the same call keeps the earlier one.
					const memo = await api.memo<MemoDecision>(
						memoName,
						decision.kind === "allow" ? "allow" : { block: decision.reason },
						context,
					);
					if (decision.kind === "allow" && decision.rememberForSession) {
						await broker.rememberTool(api.conversationId, call.name);
					}
					return apply(memo);
				},
			}),
		],
	});
}

function apply(memo: MemoDecision): { readonly block: string } | undefined {
	return memo === "allow" ? undefined : { block: memo.block };
}
