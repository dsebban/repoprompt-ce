import {
	clampThinkingLevel,
	getSupportedThinkingLevels,
	type Model,
	type Models,
	type ModelThinkingLevel,
} from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import type { HarnessSettings, ModelRef } from "@earendil-works/pi-durable";
// pi's own host configuration: auth.json, models.json, settings.json, and its HTTP setup. Imported from the
// pinned monorepo source (this package builds inside it), as the reference durable TUI does.
import { ModelRuntime } from "../../coding-agent/src/core/model-runtime.ts";
import { SettingsManager } from "../../coding-agent/src/core/settings-manager.ts";
import {
	configureHarnessHttp,
	createHarnessSettings,
	findInitialAgentModel,
} from "../../coding-agent/src/experimental/durable/harness-setup.ts";

/** One selectable model: a `provider/modelId` value credentialed on this host. */
export interface ModelOption {
	readonly value: string;
	readonly name: string;
	readonly ref: ModelRef;
	readonly contextWindow?: number;
	readonly thinkingLevels: readonly ModelThinkingLevel[];
}

export interface InitialAgentModel {
	readonly model?: ModelRef;
	readonly thinkingLevel?: ModelThinkingLevel;
}

/** The models and run policy of this host. Credentials are host-owned; RepoPrompt forwards none. */
export interface HostModels {
	readonly models: Models;
	options(): readonly ModelOption[];
	find(value: string): ModelOption | undefined;
	/** The model a new session starts with: pi's `settings.json` default resolution. */
	initial(cwd: string): Promise<InitialAgentModel>;
	settings(cwd: string): HarnessSettings | undefined;
	clampThinking(option: ModelOption, level: string | undefined): ModelThinkingLevel;
}

export function modelValue(ref: ModelRef): string {
	return `${ref.provider}/${ref.modelId}`;
}

function optionOf(model: Model<string>): ModelOption {
	return {
		value: `${model.provider}/${model.id}`,
		name: model.name,
		ref: { provider: model.provider, modelId: model.id },
		contextWindow: model.contextWindow,
		thinkingLevels: getSupportedThinkingLevels(model),
	};
}

function clamp(models: Models, option: ModelOption, level: string | undefined): ModelThinkingLevel {
	const model = models.getModel(option.ref.provider, option.ref.modelId);
	const requested = (level ?? "off") as ModelThinkingLevel;
	if (model === undefined) return option.thinkingLevels.includes(requested) ? requested : "off";
	return clampThinkingLevel(model, requested);
}

/** pi's `ModelRuntime`: the models credentialed on this host (`~/.pi/agent/auth.json`, `models.json`, env keys). */
export async function createHostModels(cwd: string): Promise<HostModels> {
	const settingsManager = SettingsManager.create(cwd);
	// Without pi's HTTP setup some provider streams end early.
	configureHarnessHttp(settingsManager);
	const runtime = await ModelRuntime.create();
	const options = (): ModelOption[] => runtime.getAvailableSnapshot().map((model) => optionOf(model as Model<string>));
	return {
		models: runtime,
		options,
		find: (value) => options().find((option) => option.value === value),
		initial: async (sessionCwd) => {
			const initial = await findInitialAgentModel(SettingsManager.create(sessionCwd), runtime);
			return {
				...(initial.model === undefined ? {} : { model: initial.model }),
				...(initial.thinkingLevel === undefined ? {} : { thinkingLevel: initial.thinkingLevel }),
			};
		},
		settings: (sessionCwd) => createHarnessSettings(SettingsManager.create(sessionCwd)),
		clampThinking: (option, level) => clamp(runtime, option, level),
	};
}

/** pi-durable's fixed summarization prompt, which follows the serialized `<conversation>` (`harness/compaction.ts`). */
const SUMMARIZATION_REQUEST = "The messages above are a conversation to summarize";

/**
 * Deterministic test model (`RP_PI_DURABLE_FAUX=1`). It decides from the transcript, so it behaves the same after a
 * restart:
 * - `run: <command>` calls `bash` with the command, then answers `ran: <first output line>`;
 * - anything else answers `faux: <text>`.
 * Test knobs: `RP_PI_DURABLE_FAUX_TPS` streams at that many tokens per second;
 * `RP_PI_DURABLE_FAUX_KEEP_TOKENS` and `RP_PI_DURABLE_FAUX_FAIL_COMPACTION=1` exercise compaction.
 */
export function createFauxHostModels(): HostModels {
	const faux = fauxProvider({ tokensPerSecond: Number(process.env.RP_PI_DURABLE_FAUX_TPS ?? "0") || undefined });
	const step = (context: { messages: readonly { role: string; content: unknown }[] }) => {
		const messages = context.messages;
		const lastUser = messages.findLastIndex((message) => message.role === "user");
		const text = textOf(messages[lastUser]?.content).trim();
		if (text.includes(SUMMARIZATION_REQUEST) && process.env.RP_PI_DURABLE_FAUX_FAIL_COMPACTION === "1") {
			// A non-retryable summarization failure: the compaction task fails with `model_error`.
			return fauxAssistantMessage([], { stopReason: "length" });
		}
		const results = messages.slice(lastUser + 1).filter((message) => message.role === "toolResult");
		if (text.startsWith("run:")) {
			if (results.length === 0) {
				return fauxAssistantMessage([fauxToolCall("bash", { command: text.slice(4).trim() })], {
					stopReason: "toolUse",
				});
			}
			const output = textOf(results.at(-1)?.content).split("\n")[0] ?? "";
			return fauxAssistantMessage([fauxText(`ran: ${output}`)]);
		}
		return fauxAssistantMessage([fauxText(`faux: ${text}`)]);
	};
	faux.setResponses(Array.from({ length: 10_000 }, () => step as never));
	const models = createModels();
	models.setProvider(faux.provider);
	const options = (): ModelOption[] => faux.models.map((model) => optionOf(model));
	return {
		models,
		options,
		find: (value) => options().find((option) => option.value === value),
		initial: async () => {
			const first = options()[0];
			return first === undefined ? {} : { model: first.ref };
		},
		// `RP_PI_DURABLE_FAUX_KEEP_TOKENS` shrinks the verbatim window so `/compact` actually summarizes.
		settings: () => {
			const keepRecentTokens = Number(process.env.RP_PI_DURABLE_FAUX_KEEP_TOKENS);
			return Number.isFinite(keepRecentTokens) && keepRecentTokens > 0
				? { compaction: { keepRecentTokens } }
				: undefined;
		},
		clampThinking: (option, level) => clamp(models, option, level),
	};
}

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.flatMap((block: { type?: string; text?: string }) =>
			block.type === "text" && typeof block.text === "string" ? [block.text] : [],
		)
		.join("\n");
}
