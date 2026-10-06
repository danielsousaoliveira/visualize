import { afterAll, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { envFileKeys, parseEnvFile } from "../src/core/env-file";
import type { ScanEnvVariable } from "../src/scan/contract";
import { scanFolder } from "../src/scan/scan-folder";

const FIXTURES_DIR = fileURLToPath(new URL("../fixtures", import.meta.url));
const workspace = mkdtempSync(join(tmpdir(), "visualize-env-"));

afterAll(() => rmSync(workspace, { recursive: true, force: true }));

function folder(name: string, files: Record<string, string>): string {
  const root = join(workspace, name);
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(join(root, path, ".."), { recursive: true });
    writeFileSync(join(root, path), content);
  }
  return root;
}

function statuses(variables: ScanEnvVariable[]): Record<string, string> {
  return Object.fromEntries(variables.map(({ name, status }) => [name, status]));
}

async function requirementsOf(root: string) {
  const result = await scanFolder(root);
  return {
    byService: Object.fromEntries(
      result.envRequirements.map(({ serviceId, variables }) => [serviceId, variables]),
    ),
    warnings: result.warnings.filter((warning) => /env_file|Env file/.test(warning)),
  };
}

const NODE_APP = JSON.stringify({ name: "svc", scripts: { start: "node server.js" } });

describe("env requirements from the scan fixtures", () => {
  it("reports set, missing and extra keys for a single app", async () => {
    const { byService } = await requirementsOf(join(FIXTURES_DIR, "scan", "env-requirements"));
    expect(statuses(byService["."]!)).toEqual({
      A: "set",
      B: "missing",
      C: "missing",
      EXTRA_TOKEN: "extra",
      LOCAL_ONLY: "set",
    });
  });

  it("names every file that declares a key", async () => {
    const { byService } = await requirementsOf(join(FIXTURES_DIR, "scan", "env-requirements"));
    const local = byService["."]!.find(({ name }) => name === "LOCAL_ONLY");
    expect(local?.declaredIn).toEqual([".env.example", ".env.local"]);
  });

  it("keeps each monorepo app's requirements separate", async () => {
    const { byService } = await requirementsOf(join(FIXTURES_DIR, "scan", "monorepo"));
    expect(statuses(byService["apps/api"]!)).toEqual({ API_KEY: "set", DATABASE_URL: "missing" });
    expect(statuses(byService["apps/web"]!)).toEqual({ NEXT_PUBLIC_API_URL: "missing" });
  });

  it("counts a compose env_file as set", async () => {
    const { byService, warnings } = await requirementsOf(join(FIXTURES_DIR, "scan", "env-compose"));
    expect(byService["compose:api"]).toEqual([
      { name: "X", status: "set", declaredIn: ["api/.env.example", "api/app.env"] },
      { name: "Y", status: "missing", declaredIn: ["api/.env.example"] },
    ]);
    expect(warnings).toEqual([]);
  });
});

describe("env files the scan cannot fully read", () => {
  it("warns about a malformed line and still reports the other keys", async () => {
    const root = folder("malformed", {
      "package.json": NODE_APP,
      ".env.example": "GOOD=\nOTHER=\n",
      ".env": "GOOD=fixture-good\nthis is not an assignment\n\nOTHER=fixture-other\n",
    });
    const { byService, warnings } = await requirementsOf(root);
    expect(statuses(byService["."]!)).toEqual({ GOOD: "set", OTHER: "set" });
    expect(warnings).toEqual(["Env file .env, line 2, could not be parsed and was skipped."]);
  });

  it("warns once about a root file shared by several services", async () => {
    const root = folder("shared-malformed", {
      ".env": "1BAD=x\n",
      "docker-compose.yml": "services:\n  a:\n    image: nginx\n  b:\n    image: nginx\n",
    });
    const { warnings } = await requirementsOf(root);
    expect(warnings).toEqual(["Env file .env, line 1, could not be parsed and was skipped."]);
  });

  it("warns about a required env_file that does not exist, but not an optional one", async () => {
    const root = folder("missing-env-file", {
      "docker-compose.yml": [
        "services:",
        "  web:",
        "    image: nginx",
        "    env_file:",
        "      - ./missing.env",
        "      - path: ./optional.env",
        "        required: false",
        "",
      ].join("\n"),
    });
    const { warnings } = await requirementsOf(root);
    expect(warnings).toEqual(['Service "web": env_file missing.env was not found.']);
  });

  it("does not read an env_file outside the project", async () => {
    const root = folder("outside-env-file", {
      "docker-compose.yml": "services:\n  web:\n    image: nginx\n    env_file: ../outside.env\n",
    });
    writeFileSync(join(workspace, "outside.env"), "LEAKED=fixture-outside\n");
    const { byService, warnings } = await requirementsOf(root);
    expect(byService["compose:web"]).toEqual([]);
    expect(warnings).toEqual([
      'Service "web": env_file ../outside.env is not a path inside the project and was not read.',
    ]);
  });
});

describe("env file keys", () => {
  it("treats a bare key as declared without a value", () => {
    expect(envFileKeys("export TOKEN\nNAME\n").keys).toEqual([
      { key: "TOKEN", hasValue: false },
      { key: "NAME", hasValue: false },
    ]);
  });

  it("treats an empty quoted value as unset", () => {
    expect(envFileKeys('A=""\nB=\'\'\nC=x\n').keys).toEqual([
      { key: "A", hasValue: false },
      { key: "B", hasValue: false },
      { key: "C", hasValue: true },
    ]);
  });

  it("counts lines across a multi-line quoted value", () => {
    const parsed = envFileKeys('# comment\nKEY="one\ntwo"\n-bad\n');
    expect(parsed.keys).toEqual([{ key: "KEY", hasValue: true }]);
    expect(parsed.malformedLines).toEqual([4]);
  });

  it("flags an unterminated quote", () => {
    expect(envFileKeys('A=1\nB="never closed\n').malformedLines).toEqual([2]);
  });

  it("leaves parseEnvFile entries unchanged by bare keys", () => {
    expect(parseEnvFile("BARE\nA=1\n")).toEqual([{ key: "A", value: "1", interpolation: "1" }]);
  });
});

describe("env values stay out of the output", () => {
  const MIN_CHECKED_LENGTH = 4;
  const PORT = /^\d{1,5}$/;

  function envFilesUnder(directory: string): string[] {
    return readdirSync(directory, { withFileTypes: true, recursive: true })
      .filter((entry) => entry.isFile() && /^\.env|\.env$/.test(entry.name))
      .map((entry) => join(entry.parentPath, entry.name));
  }

  const fixtures = ["deploy", "scan"].flatMap((group) =>
    readdirSync(join(FIXTURES_DIR, group), { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => join(FIXTURES_DIR, group, entry.name)),
  );

  it("checks every fixture env file", () => {
    expect(fixtures.flatMap(envFilesUnder).length).toBeGreaterThanOrEqual(8);
  });

  for (const root of fixtures) {
    const values = envFilesUnder(root)
      .flatMap((path) => parseEnvFile(readFileSync(path, "utf-8")))
      .map(({ value }) => value)
      .filter((value) => value.length >= MIN_CHECKED_LENGTH && !PORT.test(value));
    if (values.length === 0) continue;

    it(`${root.slice(FIXTURES_DIR.length + 1)} prints no env value`, async () => {
      const output = JSON.stringify(await scanFolder(root));
      for (const value of values) expect(output).not.toContain(value);
    });
  }
});
