// Keyless smoke-test model (PI_PROVIDER=faux). It lets you prove the phone → cloud →
// bridge → RepoPrompt path works before adding a real model key:
//   "/tool rp_workspaces {"action":"list"}"  → calls that tool, then echoes the result
//   anything else                              → replies "faux: <your text>"

import {
  fauxAssistantMessage,
  fauxText,
  fauxToolCall,
  registerFauxProvider,
  type Model,
} from "@mariozechner/pi-ai";

let registered: Model<string> | null = null;

function lastText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((c: { type: string; text?: string }) => (c.type === "text" ? (c.text ?? "") : "")).join("");
}

export function fauxModel(): Model<string> {
  if (registered) return registered;
  const faux = registerFauxProvider({ provider: "faux", models: [{ id: "faux-smoke" }], tokensPerSecond: 0 });
  const respond = (context: { messages: Array<{ role: string; content: unknown; isError?: boolean }> }) => {
    const last = context.messages[context.messages.length - 1];
    if (last?.role === "toolResult") {
      return fauxAssistantMessage(`${last.isError ? "TOOL ERROR" : "TOOL RESULT"}: ${lastText(last.content).slice(0, 2000)}`);
    }
    const text = lastText(last?.content).trim();
    const match = text.match(/^\/tool\s+(\S+)\s*(\{[\s\S]*\})?$/);
    if (match) {
      return fauxAssistantMessage([fauxToolCall(match[1], match[2] ? JSON.parse(match[2]) : {})], { stopReason: "toolUse" });
    }
    return fauxAssistantMessage([fauxText(`faux: ${text}`)]);
  };
  // Each response re-queues the factory, so the queue never runs dry.
  const step = (context: Parameters<typeof respond>[0]) => {
    faux.appendResponses([step as never]);
    return respond(context);
  };
  faux.setResponses([step as never]);
  const model = faux.getModel();
  registered = model;
  return model;
}
