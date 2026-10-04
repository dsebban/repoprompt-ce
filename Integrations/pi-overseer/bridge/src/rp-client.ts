// Thin MCP client over RepoPrompt CE's stdio server (`repoprompt-mcp --backend app`).

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

export interface RPClientOptions {
  command: string;
  args: string[];
  defaultWindowID: number | null;
  maxResultChars: number;
  log: (msg: string) => void;
}

export interface ToolOutcome {
  text: string;
  isError: boolean;
}

export class RPClient {
  private client: Client | null = null;
  private connecting: Promise<Client> | null = null;

  constructor(private readonly opts: RPClientOptions) {}

  private async connect(): Promise<Client> {
    if (this.client) return this.client;
    if (this.connecting) return this.connecting;
    this.connecting = (async () => {
      const transport = new StdioClientTransport({
        command: this.opts.command,
        args: this.opts.args,
        // The SDK otherwise passes only a minimal default environment.
        env: Object.fromEntries(
          Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined),
        ),
        stderr: "pipe",
      });
      const client = new Client({ name: "pi-overseer-bridge", version: "0.1.0" });
      transport.onclose = () => {
        this.opts.log("RepoPrompt MCP transport closed; will reconnect on next call");
        this.client = null;
      };
      await client.connect(transport);
      this.opts.log(`Connected to RepoPrompt MCP via ${this.opts.command}`);
      this.client = client;
      return client;
    })();
    try {
      return await this.connecting;
    } finally {
      this.connecting = null;
    }
  }

  async call(tool: string, args: Record<string, unknown>, timeoutMs = 180_000): Promise<ToolOutcome> {
    // Watcher and phone views consume the MCP data contract, not formatted Markdown.
    const routed: Record<string, unknown> = { ...args, _rawJSON: true };
    // Window-scoped tools route through `_windowID`; global tools ignore it.
    if (routed._windowID === undefined && this.opts.defaultWindowID !== null && tool !== "bind_context") {
      routed._windowID = this.opts.defaultWindowID;
    }
    let lastError: unknown;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const client = await this.connect();
        const result = await client.callTool({ name: tool, arguments: routed }, undefined, {
          timeout: timeoutMs,
          resetTimeoutOnProgress: true,
        });
        const content = (result.content ?? []) as Array<{ type: string; text?: string }>;
        const text = content
          .filter((c) => c.type === "text" && typeof c.text === "string")
          .map((c) => c.text)
          .join("\n");
        return { text: this.truncate(text), isError: Boolean(result.isError) };
      } catch (error) {
        lastError = error;
        // A dead transport is worth one reconnect; a tool-level error is not.
        if (this.client === null && attempt === 0) continue;
        break;
      }
    }
    throw lastError;
  }

  private truncate(text: string): string {
    // JSON is an atomic data contract for phone views and the watcher. Slicing it
    // corrupts otherwise successful MCP responses; the cap applies only to prose.
    try {
      JSON.parse(text);
      return text;
    } catch {
      // Non-JSON tool output is still bounded before crossing the wire.
    }
    const max = this.opts.maxResultChars;
    if (text.length <= max) return text;
    return `${text.slice(0, max)}\n…[truncated ${text.length - max} chars by bridge]`;
  }

  async close(): Promise<void> {
    await this.client?.close().catch(() => {});
    this.client = null;
  }
}
