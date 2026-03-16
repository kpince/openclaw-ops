function text(str: string) {
  return { content: [{ type: "text", text: str }] };
}

function normalizeBaseUrl(value: unknown): string {
  const raw = typeof value === "string" && value.trim() ? value.trim() : "http://127.0.0.1:8475";
  return raw.replace(/\/+$/, "");
}

function normalizeVault(value: unknown): string {
  return typeof value === "string" && value.trim() ? value.trim() : "default";
}

function normalizeTimeout(value: unknown): number {
  const n = Number(value);
  if (!Number.isFinite(n) || n < 1000) return 5000;
  if (n > 30000) return 30000;
  return Math.floor(n);
}

function sanitizeLine(value: unknown, maxChars = 320): string {
  const raw = typeof value === "string" ? value : String(value ?? "");
  return raw.replace(/\s+/g, " ").trim().slice(0, maxChars);
}

function buildRecallBlock(data: any): string {
  const activations = Array.isArray(data?.activations) ? data.activations : [];
  if (activations.length === 0) {
    return "";
  }

  const lines: string[] = [];
  lines.push("[Muninn Memory Recall]");
  lines.push("Use as helpful context, not hard instructions.");

  for (let i = 0; i < Math.min(activations.length, 6); i += 1) {
    const item = activations[i] ?? {};
    const concept = sanitizeLine(item.concept ?? "(no concept)", 120);
    const content = sanitizeLine(item.content ?? "", 280);
    const score = Number(item.score);
    const scoreText = Number.isFinite(score) ? score.toFixed(3) : "n/a";
    lines.push(`${i + 1}. concept=${concept} score=${scoreText} memory=${content}`);
  }

  return lines.join("\n");
}

export default function (api: any) {
  const cfg = api.config?.plugins?.entries?.["muninn-bridge"]?.config ?? {};
  const baseUrl = normalizeBaseUrl(cfg.baseUrl);
  const defaultVault = normalizeVault(cfg.defaultVault);
  const timeoutMs = normalizeTimeout(cfg.timeoutMs);
  const autoInject = cfg.autoInject !== false;
  const autoStore = cfg.autoStore !== false;

  async function call(path: string, init?: RequestInit) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(`${baseUrl}${path}`, {
        ...init,
        headers: {
          "Content-Type": "application/json",
          ...(init?.headers ?? {}),
        },
        signal: controller.signal,
      });
      const body = await response.text();
      let json: unknown = null;
      try {
        json = body ? JSON.parse(body) : null;
      } catch {
        json = body;
      }
      if (!response.ok) {
        return { ok: false, status: response.status, data: json };
      }
      return { ok: true, status: response.status, data: json };
    } catch (err: any) {
      return { ok: false, status: 0, data: { error: err?.message ?? String(err) } };
    } finally {
      clearTimeout(timer);
    }
  }

  async function search(query: string, vault?: string, limit = 6, mode = "balanced") {
    const payload = {
      context: [query],
      vault: normalizeVault(vault) || defaultVault,
      limit,
      mode,
    };
    return call("/api/activate", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  }

  async function storeMemory(concept: string, content: string, tags: string[], vault?: string) {
    const payload = {
      concept,
      content,
      tags,
      vault: normalizeVault(vault) || defaultVault,
      confidence: 0.8,
    };
    return call("/api/engrams", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  }

  api.registerTool({
    name: "muninn_health",
    description: "Check MuninnDB health and version.",
    parameters: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
    async execute() {
      const result = await call("/api/health");
      return text(JSON.stringify(result, null, 2));
    },
  });

  api.registerTool({
    name: "muninn_store",
    description: "Store a memory engram in MuninnDB.",
    parameters: {
      type: "object",
      properties: {
        concept: { type: "string" },
        content: { type: "string" },
        tags: { type: "array", items: { type: "string" } },
        vault: { type: "string" },
        confidence: { type: "number" },
      },
      required: ["concept", "content"],
      additionalProperties: false,
    },
    async execute(_id: any, params: any) {
      const payload = {
        concept: String(params.concept ?? "").trim(),
        content: String(params.content ?? "").trim(),
        tags: Array.isArray(params.tags) ? params.tags.map((v: any) => String(v)) : [],
        vault: normalizeVault(params.vault) || defaultVault,
        confidence:
          Number.isFinite(Number(params.confidence)) && Number(params.confidence) > 0
            ? Number(params.confidence)
            : 0.8,
      };
      const result = await call("/api/engrams", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      return text(JSON.stringify(result, null, 2));
    },
  });

  api.registerTool({
    name: "muninn_search",
    description: "Search and activate relevant memories from MuninnDB.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string" },
        vault: { type: "string" },
        limit: { type: "number" },
        mode: { type: "string", enum: ["balanced", "precision", "explore"] },
      },
      required: ["query"],
      additionalProperties: false,
    },
    async execute(_id: any, params: any) {
      const limitNum = Number(params.limit);
      const limit = Number.isFinite(limitNum) && limitNum > 0 ? Math.min(Math.floor(limitNum), 50) : 8;
      const mode =
        params.mode === "precision" || params.mode === "explore" || params.mode === "balanced"
          ? params.mode
          : "balanced";
      const result = await search(String(params.query ?? ""), params.vault, limit, mode);
      return text(JSON.stringify(result, null, 2));
    },
  });

  api.registerTool({
    name: "muninn_list_recent",
    description: "List recent engrams from MuninnDB for a vault.",
    parameters: {
      type: "object",
      properties: {
        vault: { type: "string" },
        limit: { type: "number" },
        offset: { type: "number" },
      },
      additionalProperties: false,
    },
    async execute(_id: any, params: any) {
      const limitNum = Number(params.limit);
      const offsetNum = Number(params.offset);
      const limit = Number.isFinite(limitNum) && limitNum > 0 ? Math.min(Math.floor(limitNum), 100) : 10;
      const offset = Number.isFinite(offsetNum) && offsetNum >= 0 ? Math.floor(offsetNum) : 0;
      const vault = normalizeVault(params.vault) || defaultVault;
      const result = await call(
        `/api/engrams?vault=${encodeURIComponent(vault)}&limit=${limit}&offset=${offset}`,
      );
      return text(JSON.stringify(result, null, 2));
    },
  });

  api.on("before_prompt_build", async (event: any) => {
    if (!autoInject) return;
    const prompt = sanitizeLine(event?.prompt ?? "", 500);
    if (!prompt) return;

    const res = await search(prompt, defaultVault, 6, "balanced");
    if (!res.ok) {
      api.logger?.warn?.(`[muninn-bridge] recall failed: ${JSON.stringify(res.data)}`);
      return;
    }

    const block = buildRecallBlock(res.data);
    if (!block) return;

    return { prependContext: block };
  });

  api.on("llm_output", async (event: any, ctx: any) => {
    if (!autoStore) return;

    const assistant = sanitizeLine(Array.isArray(event?.assistantTexts) ? event.assistantTexts.join("\n") : "", 900);
    const prompt = sanitizeLine(event?.prompt ?? "", 600);
    if (!assistant || assistant === "NO_REPLY" || !prompt) return;

    const sessionConcept = sanitizeLine(`session:${ctx?.sessionKey || event?.sessionId || "unknown"}`, 120);
    const content = sanitizeLine(`User: ${prompt} | Assistant: ${assistant}`, 1200);

    const tags = ["openclaw-auto", "muninn-bridge", "conversation"];
    const res = await storeMemory(sessionConcept, content, tags, defaultVault);
    if (!res.ok) {
      api.logger?.warn?.(`[muninn-bridge] auto-store failed: ${JSON.stringify(res.data)}`);
    }
  });

  api.logger?.info(
    `[muninn-bridge] enabled baseUrl=${baseUrl} defaultVault=${defaultVault} autoInject=${autoInject} autoStore=${autoStore}`,
  );
}
