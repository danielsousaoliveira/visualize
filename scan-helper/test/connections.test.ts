import { afterAll, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { scanFolder } from "../src/scan/scan-folder";

const FIXTURES_DIR = fileURLToPath(new URL("../fixtures/scan", import.meta.url));
const workspace = mkdtempSync(join(tmpdir(), "visualize-connections-"));

afterAll(() => rmSync(workspace, { recursive: true, force: true }));

function folder(name: string, files: Record<string, string>): string {
  const root = join(workspace, name);
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(join(root, path, ".."), { recursive: true });
    writeFileSync(join(root, path), content);
  }
  return root;
}

async function connectionsOf(root: string) {
  const result = await scanFolder(root);
  return {
    connections: result.connections,
    warnings: result.warnings.filter((warning) => /connection is left out/.test(warning)),
  };
}

function nodeApp(name: string, port: number, extra: Record<string, unknown> = {}): string {
  return JSON.stringify({ name, scripts: { start: `PORT=${port} node server.js` }, ...extra });
}

const PNPM_ROOT = {
  "package.json": JSON.stringify({ name: "root", private: true }),
  "pnpm-workspace.yaml": 'packages:\n  - "apps/*"\n  - "packages/*"\n',
  "pnpm-lock.yaml": "lockfileVersion: '9.0'\n",
};

describe("connections from the scan fixtures", () => {
  it("adds a depends_on edge from api to each of db and cache", async () => {
    const { connections } = await connectionsOf(join(FIXTURES_DIR, "compose-env"));
    expect(connections.filter(({ kind }) => kind === "depends_on")).toEqual([
      { from: "compose:api", to: "compose:db", kind: "depends_on", label: "depends_on" },
      { from: "compose:api", to: "compose:cache", kind: "depends_on", label: "depends_on" },
    ]);
  });

  it("links DATABASE_URL on host db to the db compose service", async () => {
    const { connections } = await connectionsOf(join(FIXTURES_DIR, "compose-env"));
    expect(connections.filter(({ kind }) => kind === "env-url")).toEqual([
      { from: "compose:api", to: "compose:db", kind: "env-url", label: "DATABASE_URL" },
    ]);
  });

  it("links web to the API on port 4000 through NEXT_PUBLIC_API_URL", async () => {
    const { connections, warnings } = await connectionsOf(join(FIXTURES_DIR, "connections-workspace"));
    expect(connections).toContainEqual({
      from: "apps/web",
      to: "apps/api",
      kind: "env-url",
      label: "NEXT_PUBLIC_API_URL",
    });
    expect(warnings).toEqual([]);
  });

  it("links a service using pg to the Postgres infra entry", async () => {
    const { connections } = await connectionsOf(join(FIXTURES_DIR, "infra-node-pg"));
    expect(connections).toEqual([{ from: ".", to: "infra:postgres", kind: "uses-infra", label: "postgres" }]);
  });

  it("adds a workspace-dep edge to an app package and none to a library package", async () => {
    const { connections } = await connectionsOf(join(FIXTURES_DIR, "connections-workspace"));
    const workspaceDeps = connections.filter(({ kind }) => kind === "workspace-dep");
    expect(workspaceDeps).toEqual([{ from: "apps/web", to: "apps/api", kind: "workspace-dep", label: "api" }]);
    expect(connections.some(({ to }) => to.includes("api-client"))).toBe(false);
  });
});

describe("env URL matching", () => {
  it("warns and adds no edge for a localhost port no service listens on", async () => {
    const root = folder("unmatched-port", {
      "package.json": nodeApp("svc", 3000),
      ".env": "API_URL=http://localhost:9999\n",
    });
    expect(await connectionsOf(root)).toEqual({
      connections: [],
      warnings: [
        'Service "svc": API_URL points at localhost:9999, which matches nothing in the scan; the connection is left out.',
      ],
    });
  });

  it("matches 127.0.0.1 like localhost and ignores the service's own port", async () => {
    const root = folder("loopback", {
      ...PNPM_ROOT,
      "apps/web/package.json": nodeApp("web", 3000),
      "apps/web/.env": "VITE_API_URL=http://127.0.0.1:4000\nPUBLIC_URL=http://localhost:3000\n",
      "apps/api/package.json": nodeApp("api", 4000),
    });
    expect(await connectionsOf(root)).toEqual({
      connections: [{ from: "apps/web", to: "apps/api", kind: "env-url", label: "VITE_API_URL" }],
      warnings: [],
    });
  });

  it("collapses two keys pointing at the same service into one edge", async () => {
    const root = folder("duplicate-keys", {
      ...PNPM_ROOT,
      "apps/web/package.json": nodeApp("web", 3000),
      "apps/web/.env": "API_URL=http://localhost:4000\nBACKEND_URL=http://localhost:4000/v1\n",
      "apps/web/.env.example": "API_URL=http://localhost:4000\n",
      "apps/api/package.json": nodeApp("api", 4000),
    });
    expect((await connectionsOf(root)).connections).toEqual([
      { from: "apps/web", to: "apps/api", kind: "env-url", label: "API_URL" },
    ]);
  });

  it("warns instead of guessing when two services listen on the port", async () => {
    const root = folder("ambiguous", {
      ...PNPM_ROOT,
      "apps/web/package.json": nodeApp("web", 3000),
      "apps/web/.env": "API_URL=http://localhost:4000\n",
      "apps/api/package.json": nodeApp("api", 4000),
      "apps/admin/package.json": nodeApp("admin", 4000),
    });
    const { connections, warnings } = await connectionsOf(root);
    expect(connections).toEqual([]);
    expect(warnings).toEqual([
      'Service "web": API_URL points at localhost:4000, which matches apps/admin, apps/api; the connection is left out.',
    ]);
  });

  it("links a local service to a sibling app named in the URL host", async () => {
    const root = folder("app-hostname", {
      ...PNPM_ROOT,
      "apps/web/package.json": nodeApp("web", 3000),
      "apps/web/.env": "API_URL=http://api:4000\nDATABASE_URL=postgres://u:p@db:5432/x\n",
      "apps/api/package.json": nodeApp("api", 4000),
    });
    expect(await connectionsOf(root)).toEqual({
      connections: [
        { from: "apps/web", to: "apps/api", kind: "env-url", label: "API_URL" },
        { from: "apps/web", to: "infra:postgres", kind: "env-url", label: "DATABASE_URL" },
        { from: "apps/web", to: "infra:postgres", kind: "uses-infra", label: "postgres" },
      ],
      warnings: [],
    });
  });

  it("warns about a dotless host that names no service", async () => {
    const root = folder("unknown-hostname", {
      "package.json": nodeApp("svc", 3000),
      ".env": "AUTH_URL=http://auth:9000\n",
    });
    expect((await connectionsOf(root)).warnings).toEqual([
      'Service "svc": AUTH_URL points at auth:9000, which matches nothing in the scan; the connection is left out.',
    ]);
  });

  it("warns about a database URL on an external host with no infra entry", async () => {
    const root = folder("hosted-infra", {
      "package.json": nodeApp("svc", 3000),
      ".env.sample": "CACHE_URL=redis://cache.example.com:6379\n",
    });
    expect(await connectionsOf(root)).toEqual({
      connections: [],
      warnings: [
        'Service "svc": CACHE_URL points at cache.example.com:6379, which matches nothing in the scan; the connection is left out.',
      ],
    });
  });

  it("links a database URL on an external host to its infra entry", async () => {
    const root = folder("hosted-infra-entry", {
      "package.json": nodeApp("svc", 3000),
      ".env": "DATABASE_URL=postgres://u:p@prod.db.example.com:5432/x\n",
    });
    expect((await connectionsOf(root)).connections).toContainEqual({
      from: ".",
      to: "infra:postgres",
      kind: "env-url",
      label: "DATABASE_URL",
    });
  });

  it("ignores external hosts without a warning", async () => {
    const root = folder("external", {
      "package.json": nodeApp("svc", 3000),
      ".env": "STRIPE_URL=https://api.stripe.com\nUPSTREAM=http://example.com:8080\n",
    });
    expect(await connectionsOf(root)).toEqual({ connections: [], warnings: [] });
  });

  it("links a local service to a compose service through its published port", async () => {
    const root = folder("published-port", {
      "docker-compose.yml": [
        "services:",
        "  web:",
        "    build: ./web",
        "    environment:",
        "      API_URL: http://localhost:4000",
        "  api:",
        "    build: ./api",
        "    ports:",
        '      - "4000:4000"',
        "    environment:",
        "      WEB_URL: http://web:3000",
        "      SELF_URL: http://localhost:4000",
        "      AUTH_URL: http://auth:9000",
      ].join("\n"),
      "web/package.json": nodeApp("web", 3000),
      "api/package.json": nodeApp("api", 4000),
    });
    expect(await connectionsOf(root)).toEqual({
      connections: [{ from: "compose:api", to: "compose:web", kind: "env-url", label: "WEB_URL" }],
      warnings: [
        'Service "api": AUTH_URL points at auth:9000, which matches nothing in the scan; the connection is left out.',
      ],
    });
  });

  it("reads URLs from a compose env_file", async () => {
    const root = folder("env-file", {
      "docker-compose.yml": [
        "services:",
        "  worker:",
        "    image: node:22",
        "    env_file: ./worker.env",
        "  api:",
        "    image: node:22",
      ].join("\n"),
      "worker.env": "API_URL=http://api:8080\n",
    });
    expect((await connectionsOf(root)).connections).toEqual([
      { from: "compose:worker", to: "compose:api", kind: "env-url", label: "API_URL" },
    ]);
  });

  it("never puts env values in the output", async () => {
    const root = folder("secret-url", {
      "package.json": nodeApp("svc", 3000),
      ".env": "API_URL=http://user:fixture-url-secret@localhost:9999/path\n",
    });
    expect(JSON.stringify(await scanFolder(root))).not.toContain("fixture-url-secret");
  });
});

describe("compose depends_on", () => {
  it("keeps cycles in the data", async () => {
    const root = folder("cycle", {
      "docker-compose.yml": [
        "services:",
        "  a:",
        "    image: node:22",
        "    depends_on: [b]",
        "  b:",
        "    image: node:22",
        "    depends_on: [a]",
      ].join("\n"),
    });
    expect((await connectionsOf(root)).connections).toEqual([
      { from: "compose:a", to: "compose:b", kind: "depends_on", label: "depends_on" },
      { from: "compose:b", to: "compose:a", kind: "depends_on", label: "depends_on" },
    ]);
  });

  it("warns and drops a dependency on a service that is not in the file", async () => {
    const root = folder("missing-dependency", {
      "docker-compose.yml": ["services:", "  a:", "    image: node:22", "    depends_on: [ghost]"].join("\n"),
    });
    expect(await connectionsOf(root)).toEqual({
      connections: [],
      warnings: ['Service "a": depends_on ghost matches no compose service; the connection is left out.'],
    });
  });
});

describe("workspace dependencies", () => {
  it("links to an app listed in devDependencies by its package name", async () => {
    const root = folder("dev-dependency", {
      ...PNPM_ROOT,
      "apps/web/package.json": nodeApp("@repo/web", 3000, { devDependencies: { "@repo/api": "workspace:*" } }),
      "apps/api/package.json": nodeApp("@repo/api", 4000),
      "packages/ui/package.json": JSON.stringify({ name: "@repo/ui" }),
    });
    expect((await connectionsOf(root)).connections).toEqual([
      { from: "apps/web", to: "apps/api", kind: "workspace-dep", label: "@repo/api" },
    ]);
  });
});
