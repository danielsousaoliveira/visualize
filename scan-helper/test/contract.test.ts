import { afterAll, describe, expect, it } from "bun:test";
import Ajv2020 from "ajv/dist/2020";
import {
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
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
    ["${BIND_ADDR}:8080:80", { host: "8080", container: "80" }],
  ])("splits %s", (spec, expected) => {
    expect(toPortMapping(spec)).toEqual(expected);
  });

  it.each(["8080:8081:80", "1:2:3:4", "8080:"])("rejects %s", (spec) => {
    expect(toPortMapping(spec)).toBeUndefined();
  });

  it("leaves an unreadable port out and warns about it", async () => {
    const root = mkdtempSync(join(tmpdir(), "visualize-ports-"));
    try {
      writeFileSync(
        join(root, "docker-compose.yml"),
        'services:\n  web:\n    image: nginx\n    ports: ["8080:8081:80", "9000:90"]\n',
      );
      const result = await scanFolder(root);
      expect(result.composeServices[0]!.ports).toEqual([{ host: "9000", container: "90" }]);
      expect(result.warnings).toContain(
        'Service "web": port "8080:8081:80" was not understood and is left out.',
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
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

  it("follows a worktree gitdir pointer that links back to it", async () => {
    const root = join(workspace, "wt");
    repo("main-repo", {
      ".git/worktrees/wt/HEAD": "ref: refs/heads/wt-branch\n",
      ".git/worktrees/wt/gitdir": `${join(root, ".git")}\n`,
    });
    repo("wt", { ".git": "gitdir: ../main-repo/.git/worktrees/wt\n" });
    expect(await readGitBranch(root)).toBe("wt-branch");
  });

  it("ignores a gitdir pointer without a matching worktree back-link", async () => {
    repo("elsewhere", { "worktrees/x/HEAD": "ref: refs/heads/leaked\n" });
    const noBackLink = repo("no-back-link", { ".git": "gitdir: ../elsewhere/worktrees/x\n" });
    expect(await readGitBranch(noBackLink)).toBeUndefined();

    repo("other", { "HEAD": "ref: refs/heads/leaked\n" });
    const notAWorktree = repo("not-a-worktree", { ".git": "gitdir: ../other\n" });
    expect(await readGitBranch(notAWorktree)).toBeUndefined();
  });

  it("ignores a symlinked .git or HEAD", async () => {
    const outside = repo("outside-git", { "HEAD": "ref: refs/heads/leaked\n" });
    const linkedDotGit = repo("linked-dot-git", { "README.md": "" });
    symlinkSync(outside, join(linkedDotGit, ".git"));
    expect(await readGitBranch(linkedDotGit)).toBeUndefined();

    const linkedHead = repo("linked-head", { ".git/config": "" });
    symlinkSync(join(outside, "HEAD"), join(linkedHead, ".git/HEAD"));
    expect(await readGitBranch(linkedHead)).toBeUndefined();
  });

  it("ignores branch names outside the ref charset", async () => {
    const odd = repo("odd-branch", { ".git/HEAD": "ref: refs/heads/a b\n" });
    expect(await readGitBranch(odd)).toBeUndefined();
    const dotted = repo("dotted-branch", { ".git/HEAD": "ref: refs/heads/../x\n" });
    expect(await readGitBranch(dotted)).toBeUndefined();
  });

  it("has no branch when HEAD is detached or there is no repository", async () => {
    const detached = repo("detached", { ".git/HEAD": "d855379a1b2c3d4e5f60718293a4b5c6d7e8f901\n" });
    expect(await readGitBranch(detached)).toBeUndefined();
    expect(await readGitBranch(repo("none", { "README.md": "" }))).toBeUndefined();
  });
});
