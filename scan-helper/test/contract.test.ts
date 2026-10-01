import { afterAll, describe, expect, it } from "bun:test";
import Ajv2020 from "ajv/dist/2020";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { readGitBranch } from "../src/scan/git-branch";
import { toPortMapping } from "../src/scan/output";
import { scanFolder } from "../src/scan/scan-folder";

const FIXTURES_DIR = fileURLToPath(new URL("../fixtures", import.meta.url));
const GOLDEN_DIR = fileURLToPath(new URL("./golden", import.meta.url));
const SCHEMA_PATH = fileURLToPath(new URL("../schema/scan-result.v1.schema.json", import.meta.url));
const UPDATE_GOLDEN = process.env.UPDATE_GOLDEN === "1";

const validate = new Ajv2020({ allErrors: true, strict: true }).compile(
  JSON.parse(readFileSync(SCHEMA_PATH, "utf-8")),
);

const fixtures = ["deploy", "scan"].flatMap((group) =>
  readdirSync(join(FIXTURES_DIR, group), { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => ({ group, name: entry.name })),
);

async function scanFixture(group: string, name: string): Promise<string> {
  const result = await scanFolder(join(FIXTURES_DIR, group, name));
  const portable = { ...result, project: { ...result.project, rootPath: `/fixtures/${group}/${name}` } };
  return `${JSON.stringify(portable, null, 2)}\n`;
}

describe("every fixture matches the v1 contract", () => {
  for (const { group, name } of fixtures) {
    describe(`${group}/${name}`, () => {
      it("validates against the JSON Schema with schemaVersion 1", async () => {
        const output = JSON.parse(await scanFixture(group, name));
        expect(output.schemaVersion).toBe(1);
        expect(validate(output) ? [] : validate.errors).toEqual([]);
      });

      it("matches its golden output", async () => {
        const output = await scanFixture(group, name);
        const goldenPath = join(GOLDEN_DIR, `${group}-${name}.json`);
        if (UPDATE_GOLDEN) writeFileSync(goldenPath, output);
        expect(output).toBe(readFileSync(goldenPath, "utf-8"));
      });
    });
  }
});

describe("compose environment values stay out of the output", () => {
  const VALUES = ["fixture-db-password", "fixture-api-secret", "postgres://app:"];
  const NAMES = ["DATABASE_URL", "API_SECRET", "LOG_LEVEL", "POSTGRES_PASSWORD", "POSTGRES_USER"];

  it("lists every variable name and none of the values", async () => {
    const output = await scanFixture("scan", "compose-env");
    const golden = readFileSync(join(GOLDEN_DIR, "scan-compose-env.json"), "utf-8");
    const environment = JSON.parse(output).composeServices.flatMap(
      (service: { environment: string[] }) => service.environment,
    );
    expect(environment.sort()).toEqual([...NAMES].sort());
    for (const value of VALUES) {
      expect(output).not.toContain(value);
      expect(golden).not.toContain(value);
    }
  });
});

describe("compose port mappings", () => {
  it.each([
    ["8080", { host: null, container: "8080" }],
    ["8081:8080", { host: "8081", container: "8080" }],
    ["127.0.0.1:5432:5432/tcp", { host: "5432", container: "5432" }],
    ["127.0.0.1::53/udp", { host: null, container: "53" }],
    ["[::1]:8080:80", { host: "8080", container: "80" }],
    ["${HOST_PORT:-8080}:80", { host: "${HOST_PORT:-8080}", container: "80" }],
    ["3000-3002:3000-3002", { host: "3000-3002", container: "3000-3002" }],
  ])("splits %s", (spec, expected) => {
    expect(toPortMapping(spec)).toEqual(expected);
  });
});

describe("git branch", () => {
  const workspace = mkdtempSync(join(tmpdir(), "visualize-branch-"));
  afterAll(() => rmSync(workspace, { recursive: true, force: true }));

  function repo(name: string, files: Record<string, string>): string {
    const root = join(workspace, name);
    for (const [path, content] of Object.entries(files)) {
      mkdirSync(join(root, path, ".."), { recursive: true });
      writeFileSync(join(root, path), content);
    }
    return root;
  }

  it("reads the checked-out branch", async () => {
    const root = repo("plain", { ".git/HEAD": "ref: refs/heads/feature/scan\n" });
    expect(await readGitBranch(root)).toBe("feature/scan");
  });

  it("follows a worktree gitdir pointer", async () => {
    repo("main-repo", { ".git/worktrees/wt/HEAD": "ref: refs/heads/wt-branch\n" });
    const root = repo("wt", { ".git": "gitdir: ../main-repo/.git/worktrees/wt\n" });
    expect(await readGitBranch(root)).toBe("wt-branch");
  });

  it("has no branch when HEAD is detached or there is no repository", async () => {
    const detached = repo("detached", { ".git/HEAD": "d855379a1b2c3d4e5f60718293a4b5c6d7e8f901\n" });
    expect(await readGitBranch(detached)).toBeUndefined();
    expect(await readGitBranch(repo("none", { "README.md": "" }))).toBeUndefined();
  });
});
