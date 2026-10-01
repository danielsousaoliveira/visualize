import { afterAll, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { listLocalTree } from "../src/scan/local-reader";
import { toScanOutput } from "../src/scan/output";
import { resolveFromLocal } from "../src/scan/resolve";

const workspace = mkdtempSync(join(tmpdir(), "visualize-scan-"));

afterAll(() => rmSync(workspace, { recursive: true, force: true }));

function folder(name: string, files: Record<string, string>): string {
  const root = join(workspace, name);
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(join(root, path, ".."), { recursive: true });
    writeFileSync(join(root, path), content);
  }
  return root;
}

async function scan(root: string): Promise<string> {
  return JSON.stringify(toScanOutput(await resolveFromLocal(root)));
}

describe("scan output never carries .env values", () => {
  const SECRET = "s3cr3t-token-value";
  const root = folder("compose-secret", {
    ".env": `TOKEN=${SECRET}\nREGISTRY=${SECRET}\nDATA=${SECRET}\nHOST_PORT=8081\nBAD_PORT=${SECRET}`,
    "docker-compose.yml": [
      "services:",
      "  api:",
      "    image: ${REGISTRY}/api:latest",
      '    command: ["sh", "-c", "echo ${TOKEN}"]',
      '    ports: ["${HOST_PORT}:8080"]',
      '    volumes: ["${DATA}:/data"]',
      "    environment:",
      "      API_TOKEN: ${TOKEN}",
      "    build:",
      "      context: ./api",
      "      args:",
      "        K: ${TOKEN}",
      "  worker:",
      "    image: busybox",
      '    ports: ["${BAD_PORT}:9000"]',
    ].join("\n"),
  });

  it("keeps the expression in interpolated fields", async () => {
    const output = await scan(root);
    expect(output).not.toContain(SECRET);
    const api = JSON.parse(output).services.find((s: { name: string }) => s.name === "api");
    expect(api.image).toBe("${REGISTRY}/api:latest");
    expect(api.command).toContain("${TOKEN}");
    expect(api.volumes).toEqual(["${DATA}:/data"]);
    expect(api.environmentKeys).toEqual(["API_TOKEN"]);
    expect(api.buildArgKeys).toEqual(["K"]);
  });

  it("resolves host ports only when they are plain port specs", async () => {
    const { services } = JSON.parse(await scan(root));
    const byName = Object.fromEntries(services.map((s: { name: string }) => [s.name, s]));
    expect(byName.api.ports).toEqual(["8081:8080"]);
    expect(byName.worker.ports).toEqual(["${BAD_PORT}:9000"]);
  });
});

describe("local reader stays inside the scanned folder", () => {
  it("does not read a symlinked manifest that points outside", async () => {
    const outside = folder("outside", {
      "package.json": JSON.stringify({ name: "outside-name", dependencies: { express: "^4" } }),
    });
    const root = folder("symlinked", {});
    mkdirSync(root, { recursive: true });
    symlinkSync(join(outside, "package.json"), join(root, "package.json"));
    const info = await resolveFromLocal(root);
    expect(info.repository.name).toBe("symlinked");
    expect(info.stack).not.toBe("express");
  });
});

describe("tree walk", () => {
  it("keeps only root files and root markers, and stops at the directory limit", async () => {
    const root = folder("tree", {
      "README.md": "",
      "apps/web/package.json": "{}",
      "apps/web/src/index.ts": "",
      "node_modules/x/package.json": "{}",
      "a/b/c/d/package.json": "{}",
    });
    const paths = (await listLocalTree(root)).map((entry) => entry.path).sort();
    expect(paths).toEqual(["README.md", "a/b/c/d/package.json", "apps/web/package.json"]);

    const bounded = (await listLocalTree(root, 3)).map((entry) => entry.path);
    expect(bounded).toEqual(["README.md"]);
  });
});
