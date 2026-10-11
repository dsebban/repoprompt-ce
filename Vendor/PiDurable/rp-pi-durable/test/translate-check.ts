// Event-translation regression checks: every change variant forwards exactly the text not sent yet.
// Run from the staged package inside the pinned pi checkout:
//   bun --conditions=source test/translate-check.ts
import assert from "node:assert/strict";
import type { AgentEvent } from "@earendil-works/pi-durable";
import { EventTranslator, type SessionUpdate } from "../src/translate.ts";

type Block = { type: "text"; text: string } | { type: "thinking"; thinking: string };

const message = (...content: Block[]) => ({ role: "assistant", content, usage: undefined }) as never;
const start = (...content: Block[]) => ({ type: "message_start", message: message(...content) }) as AgentEvent;
const update = (...changes: object[]) => ({ type: "message_update", usage: {}, changes }) as unknown as AgentEvent;
const end = (...content: Block[]) =>
	({
		type: "message_end",
		entry: { id: 7, kind: "pi.assistant", model: [message(...content)] },
	}) as unknown as AgentEvent;

function streamed(events: AgentEvent[]): { text: string; thinking: string } {
	const translator = new EventTranslator({ requestIdFor: () => undefined, contextWindow: () => undefined });
	const updates: SessionUpdate[] = translator.translate(events);
	const join = (kind: string) =>
		updates
			.filter((candidate) => candidate.sessionUpdate === kind)
			.map((candidate) => (candidate.content as { text: string }).text)
			.join("");
	return { text: join("agent_message_chunk"), thinking: join("agent_thought_chunk") };
}

const cases: [string, AgentEvent[], string, string?][] = [
	[
		"a populated first partial is kept before later deltas",
		[
			start({ type: "text", text: "Hello " }),
			update({ type: "text_delta", contentIndex: 0, delta: "world" }),
			end({ type: "text", text: "Hello world" }),
		],
		"Hello world",
	],
	[
		"a populated text_start is kept",
		[
			start(),
			update({ type: "text_start", contentIndex: 0, block: { type: "text", text: "Hel" } }),
			update({ type: "text_delta", contentIndex: 0, delta: "lo" }),
			end({ type: "text", text: "Hello" }),
		],
		"Hello",
	],
	[
		"a block replacement forwards only its extension",
		[
			start({ type: "text", text: "Hello" }),
			update({ type: "block", contentIndex: 0, block: { type: "text", text: "Hello wor" } }),
			end({ type: "text", text: "Hello world" }),
		],
		"Hello world",
	],
	[
		"a whole-message change forwards only its extension",
		[
			start(),
			update({ type: "message", message: message({ type: "text", text: "Hi" }) }),
			end({ type: "text", text: "Hi there" }),
		],
		"Hi there",
	],
	[
		"a message committed whole is sent at its end",
		[start(), end({ type: "text", text: "all at once" })],
		"all at once",
	],
	[
		"thinking and text blocks are tracked separately",
		[
			start({ type: "thinking", thinking: "Let me " }),
			update({ type: "thinking_delta", contentIndex: 0, delta: "think." }),
			update({ type: "text_start", contentIndex: 1, block: { type: "text", text: "Done" } }),
			end({ type: "thinking", thinking: "Let me think." }, { type: "text", text: "Done." }),
		],
		"Done.",
		"Let me think.",
	],
];

let failed = 0;
for (const [name, events, text, thinking = ""] of cases) {
	try {
		assert.deepEqual(streamed(events), { text, thinking });
		process.stdout.write(`ok   ${name}\n`);
	} catch (error) {
		failed++;
		process.stdout.write(`FAIL ${name}\n     ${(error as Error).message}\n`);
	}
}
process.stdout.write(`\n${cases.length - failed}/${cases.length} passed\n`);
process.exit(failed === 0 ? 0 : 1);
