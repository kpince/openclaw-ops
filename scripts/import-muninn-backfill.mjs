import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const ROOT = "/root/.openclaw";
const require = createRequire(import.meta.url);
const MCP_CONFIG = path.join(ROOT, "mcp.json");
const SQLITE_DB = path.join(ROOT, "memory", "memory.db");
const SQLITE_DRIVER = path.join(ROOT, "extensions", "memory-sqlite", "node_modules", "better-sqlite3");
const TARGET_VAULT = process.env.MUNINN_VAULT || "default";

const MAX_CONTENT_CHARS = 1800;
const BATCH_SIZE = 25;

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function sha(input) {
  return crypto.createHash("sha256").update(input).digest("hex");
}

function sanitize(text) {
  return text
    .replace(/sk-proj-[A-Za-z0-9_\-]{20,}/g, "[REDACTED_OPENAI_KEY]")
    .replace(/sk-ant-[A-Za-z0-9_\-]{20,}/g, "[REDACTED_ANTHROPIC_KEY]")
    .replace(/AIza[0-9A-Za-z\-_]{20,}/g, "[REDACTED_GOOGLE_KEY]")
    .replace(/\bmdb_[A-Za-z0-9]{20,}\b/g, "[REDACTED_MUNINN_TOKEN]")
    .replace(/\b[0-9a-f]{40,64}\b/gi, "[REDACTED_LONG_TOKEN]");
}

function clip(text, max = MAX_CONTENT_CHARS) {
  const trimmed = text.trim();
  if (trimmed.length <= max) return trimmed;
  return `${trimmed.slice(0, max - 3)}...`;
}

function slugify(input) {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80) || "memory";
}

function inferType(filePath, heading) {
  const joined = `${filePath} ${heading}`.toLowerCase();
  if (joined.includes("decision")) return "decision";
  if (joined.includes("infrastructure")) return "constraint";
  if (joined.includes("user")) return "identity";
  if (joined.includes("memory.md")) return "reference";
  return "reference";
}

function extractSections(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  const sanitized = sanitize(raw);
  const lines = sanitized.split(/\r?\n/);
  const title = lines.find((line) => line.startsWith("# "))?.replace(/^# /, "").trim() || path.basename(filePath);
  const sections = [];
  let currentHeading = title;
  let current = [];

  const flush = () => {
    const body = current.join("\n").trim();
    if (!body) return;
    sections.push({
      heading: currentHeading,
      body: clip(body),
    });
    current = [];
  };

  for (const line of lines) {
    if (/^##\s+/.test(line)) {
      flush();
      currentHeading = line.replace(/^##\s+/, "").trim();
      continue;
    }
    current.push(line);
  }
  flush();

  if (sections.length === 0 && sanitized.trim()) {
    sections.push({ heading: title, body: clip(sanitized) });
  }

  return sections.map((section, index) => ({
    sourcePath: filePath,
    concept: `${path.basename(filePath)}${section.heading ? ` - ${section.heading}` : ""}`,
    summary: `${path.basename(filePath)} / ${section.heading || title}`,
    content: `Source file: ${filePath}\nSection: ${section.heading}\n\n${section.body}`,
    type: inferType(filePath, section.heading),
    tags: ["markdown-import", `file:${slugify(path.basename(filePath))}`, `section:${slugify(section.heading)}`, `index:${index}`],
    op_id: `markdown:${sha(`${filePath}:${section.heading}:${section.body}`)}`,
    created_at: fs.statSync(filePath).mtime.toISOString(),
  }));
}

function readSqliteRecords() {
  const Database = require(SQLITE_DRIVER);
  const db = new Database(SQLITE_DB, { readonly: true });
  const people = db.prepare("select * from people").all();
  return people.map((row) => ({
    concept: `person:${row.name}`,
    summary: `Person record for ${row.name}`,
    content: clip(
      sanitize(
        [
          `Name: ${row.name}`,
          row.relationship ? `Relationship: ${row.relationship}` : "",
          row.notes ? `Notes: ${row.notes}` : "",
          row.contact ? `Contact: ${row.contact}` : "",
        ]
          .filter(Boolean)
          .join("\n"),
      ),
    ),
    type: "identity",
    tags: ["sqlite-import", "people"],
    entities: [{ name: row.name, type: "person" }],
    op_id: `sqlite:people:${row.id}`,
  }));
}

function walkMarkdownFiles(rootDir) {
  const output = [];
  for (const entry of fs.readdirSync(rootDir, { withFileTypes: true })) {
    const fullPath = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      output.push(...walkMarkdownFiles(fullPath));
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".md")) {
      output.push(fullPath);
    }
  }
  return output.sort();
}

function buildImportSet() {
  const files = [
    path.join(ROOT, "workspace", "USER.md"),
    path.join(ROOT, "workspace", "MEMORY.md"),
    ...walkMarkdownFiles(path.join(ROOT, "workspace", "memory")),
  ];

  const markdown = files.flatMap(extractSections);
  const sqlite = readSqliteRecords();
  return [...sqlite, ...markdown];
}

async function mcpCall(server, name, args) {
  const response = await fetch(server.url.replace("://localhost", "://127.0.0.1"), {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(server.headers ?? {}),
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: `${name}-${Date.now()}-${Math.random()}`,
      method: "tools/call",
      params: { name, arguments: args },
    }),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const payload = await response.json();
  if (payload.error) throw new Error(String(payload.error.message ?? payload.error));
  return payload.result;
}

async function main() {
  const dryRun = process.argv.includes("--dry-run");
  const mcp = readJson(MCP_CONFIG);
  const server = mcp.mcpServers?.muninn;
  if (!server) throw new Error("Muninn MCP config missing");

  const memories = buildImportSet();
  console.log(`Prepared ${memories.length} memories for import`);

  if (dryRun) {
    console.log(JSON.stringify(memories.slice(0, 5), null, 2));
    return;
  }

  for (let i = 0; i < memories.length; i += BATCH_SIZE) {
    const batch = memories.slice(i, i + BATCH_SIZE).map((entry) => ({
      concept: entry.concept,
      summary: entry.summary,
      content: entry.content,
      type: entry.type,
      tags: entry.tags,
      entities: entry.entities,
      op_id: entry.op_id,
      created_at: entry.created_at,
    }));
    const result = await mcpCall(server, "muninn_remember_batch", { memories: batch, vault: TARGET_VAULT });
    console.log(`Imported batch ${i / BATCH_SIZE + 1}: ${JSON.stringify(result.content?.[0]?.text ?? result)}`);
  }

  const status = await mcpCall(server, "muninn_status", { vault: TARGET_VAULT });
  console.log(`Final status: ${JSON.stringify(status.content?.[0]?.text ?? status)}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
