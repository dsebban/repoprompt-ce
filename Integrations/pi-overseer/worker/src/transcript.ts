// Pure transcript helpers, kept free of Workers-only imports so they are unit-testable.

import type { AgentMessage } from "@mariozechner/pi-agent-core";
import type { ToolResultMessage } from "@mariozechner/pi-ai";

export function messageText(m: AgentMessage): string {
  const content = (m as { content?: unknown }).content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((c: { type: string; text?: string; name?: string }) =>
      c.type === "text" ? (c.text ?? "") : c.type === "toolCall" ? `[${c.name}]` : "",
    )
    .filter(Boolean)
    .join("\n");
}

/**
 * Makes a persisted transcript safe to continue: every assistant tool call gets a result.
 * Returns the repaired transcript and whether the run was cut off mid-flight.
 */
export function repairTranscript(messages: AgentMessage[], now = Date.now()): { messages: AgentMessage[]; interrupted: boolean } {
  const out = [...messages];
  const last = out[out.length - 1] as { role?: string; content?: unknown } | undefined;
  if (!last) return { messages: out, interrupted: false };

  // Find the trailing assistant message and the results that follow it.
  let assistantIndex = out.length - 1;
  while (assistantIndex >= 0 && (out[assistantIndex] as { role: string }).role === "toolResult") assistantIndex--;
  const assistant = out[assistantIndex] as { role: string; content?: unknown } | undefined;
  if (assistant?.role === "assistant" && Array.isArray(assistant.content)) {
    const answered = new Set(
      out.slice(assistantIndex + 1).map((m) => (m as ToolResultMessage).toolCallId),
    );
    const missing = (assistant.content as Array<{ type: string; id: string; name: string }>).filter(
      (c) => c.type === "toolCall" && !answered.has(c.id),
    );
    for (const call of missing) {
      out.push({
        role: "toolResult",
        toolCallId: call.id,
        toolName: call.name,
        content: [
          {
            type: "text",
            text: "Interrupted: the agent restarted before this call returned. Its effect is unknown; check current state before retrying.",
          },
        ],
        isError: true,
        timestamp: now,
      } satisfies ToolResultMessage);
    }
    if (missing.length) return { messages: out, interrupted: true };
  }
  const tailRole = (out[out.length - 1] as { role: string }).role;
  return { messages: out, interrupted: tailRole === "user" || tailRole === "toolResult" };
}

/** Index of the first message to keep: at a user turn boundary so no tool result is orphaned. */
export function compactionCut(messages: AgentMessage[], keep: number): number {
  let cut = Math.max(0, messages.length - keep);
  while (cut < messages.length && (messages[cut] as { role: string }).role !== "user") cut++;
  return cut >= messages.length ? 0 : cut;
}
