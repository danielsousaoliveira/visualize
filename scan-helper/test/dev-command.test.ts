import { describe, expect, it } from "bun:test";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { StackId } from "../src/core";
import { deriveDevCommand, type DevCommandInput } from "../src/scan/dev-command";
import { scanFolder } from "../src/scan/scan-folder";

const FIXTURES_DIR = fileURLToPath(new URL("../fixtures", import.meta.url));

async function services(group: string, name: string) {
  return (await scanFolder(join(FIXTURES_DIR, group, name))).services;
}

async function onlyDevCommand(group: string, name: string) {
  const [service] = await services(group, name);
  return service!.devCommand;
}

function derive(stackId: StackId, overrides: Partial<DevCommandInput> = {}) {
  return deriveDevCommand({
    stackId,
    packageManager: null,
    scripts: {},
    startCommand: null,
    port: null,
    workingDirectory: ".",
    ...overrides,
  });
}

describe("dev command for fixtures", () => {
  it("runs the dev script through the package manager", async () => {
    expect(await onlyDevCommand("scan", "node-dev")).toEqual({
      argv: ["pnpm", "run", "dev"],
      workingDirectory: ".",
      source: "script:dev",
    });
  });

  it("runs the start script when it is the only one", async () => {
    expect(await onlyDevCommand("deploy", "node")).toEqual({
      argv: ["npm", "run", "start"],
      workingDirectory: ".",
      source: "script:start",
    });
  });

  it("runs uvicorn with reload for FastAPI", async () => {
    const command = await onlyDevCommand("deploy", "python-fastapi");
    expect(command?.argv).toEqual(["uvicorn", "main:app", "--reload", "--port", "8000"]);
    expect(command?.source).toBe("stack-default");
  });

  it("runs cargo run for Rust", async () => {
    expect((await onlyDevCommand("deploy", "rust-axum"))?.argv).toEqual(["cargo", "run"]);
  });

  it("runs go run for Go", async () => {
    expect((await onlyDevCommand("deploy", "go"))?.argv).toEqual(["go", "run", "."]);
  });

  it("runs artisan serve for Laravel", async () => {
    expect((await onlyDevCommand("deploy", "laravel"))?.argv).toEqual([
      "php",
      "artisan",
      "serve",
      "--port=8000",
    ]);
  });

  it("runs Django through uv when the project uses uv", async () => {
    expect((await onlyDevCommand("scan", "django-uv"))?.argv).toEqual([
      "uv",
      "run",
      "python",
      "manage.py",
      "runserver",
      "8000",
    ]);
  });

  it("runs each pnpm workspace app from its own directory with pnpm", async () => {
    const commands = (await services("scan", "pnpm-workspace")).map((service) => service.devCommand);
    expect(commands).toEqual([
      { argv: ["pnpm", "run", "dev"], workingDirectory: "apps/web", source: "script:dev" },
      { argv: ["pnpm", "run", "start"], workingDirectory: "apps/api", source: "script:start" },
    ]);
  });

  it("falls back to the start command for Spring Boot and .NET", async () => {
    expect(await onlyDevCommand("deploy", "springboot")).toEqual({
      argv: ["java", "-jar", "target/*.jar"],
      workingDirectory: ".",
      source: "fallback-start",
    });
    expect(await onlyDevCommand("deploy", "dotnet")).toEqual({
      argv: ["env", "ASPNETCORE_URLS=http://0.0.0.0:$PORT", "dotnet", "publish/HelloApi.dll"],
      workingDirectory: ".",
      source: "fallback-start",
    });
  });

  it("leaves image-only compose services without a dev command and says why", async () => {
    const result = await scanFolder(join(FIXTURES_DIR, "scan", "compose-env"));
    const db = result.services.find((service) => service.name === "db");
    expect(db?.devCommand).toBeNull();
    expect(result.warnings).toContain(
      'Service "db" has no dev command: it has no local source to run.',
    );
  });

  it("never chains commands with a shell operator in any fixture", async () => {
    const fixtures = ["deploy", "scan"].flatMap((group) =>
      readdirSync(join(FIXTURES_DIR, group), { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => [group, entry.name] as const),
    );
    for (const [group, name] of fixtures) {
      for (const service of await services(group, name)) {
        for (const word of service.devCommand?.argv ?? []) {
          expect(["&&", ";", "|"]).not.toContain(word);
        }
      }
    }
  });
});

describe("deriveDevCommand", () => {
  it("prefers dev over serve over start", () => {
    const scripts = { start: "node .", serve: "vite preview" };
    expect(derive("vite", { packageManager: "bun", scripts }).devCommand?.argv).toEqual([
      "bun",
      "run",
      "serve",
    ]);
    expect(
      derive("vite", { packageManager: "yarn", scripts: { ...scripts, dev: "vite" } }).devCommand
        ?.argv,
    ).toEqual(["yarn", "run", "dev"]);
  });

  it("falls back to the start command when a JS app has no scripts", () => {
    expect(derive("node", { packageManager: "npm", startCommand: "node server.js" })).toEqual({
      devCommand: { argv: ["node", "server.js"], workingDirectory: ".", source: "fallback-start" },
    });
  });

  it("ignores a package.json dev script on a non-JS stack", () => {
    expect(
      derive("laravel", { packageManager: "composer", scripts: { dev: "vite" }, port: 9000 })
        .devCommand?.argv,
    ).toEqual(["php", "artisan", "serve", "--port=9000"]);
  });

  it.each([
    ["poetry", ["poetry", "run", "flask", "run", "--debug", "--port", "5000"]],
    ["pipenv", ["pipenv", "run", "flask", "run", "--debug", "--port", "5000"]],
    ["pip", ["flask", "run", "--debug", "--port", "5000"]],
  ])("runs Flask through %s", (packageManager, argv) => {
    expect(derive("flask", { packageManager }).devCommand?.argv).toEqual(argv);
  });

  it("takes the FastAPI module from the start command", () => {
    expect(
      derive("fastapi", {
        packageManager: "uv",
        startCommand: "gunicorn -k uvicorn.workers.UvicornWorker api.server:application",
        port: 9000,
      }).devCommand?.argv,
    ).toEqual(["uv", "run", "uvicorn", "api.server:application", "--reload", "--port", "9000"]);
  });

  it("falls back to the start command when the FastAPI module is unknown", () => {
    expect(derive("fastapi", { startCommand: "python serve.py" }).devCommand).toEqual({
      argv: ["python", "serve.py"],
      workingDirectory: ".",
      source: "fallback-start",
    });
  });

  it.each([
    ["rails", ["bin/rails", "server", "-p", "3000"]],
    ["phoenix", ["mix", "phx.server"]],
    ["gin", ["go", "run", "."]],
    ["actix", ["cargo", "run"]],
  ] as const)("uses the %s default", (stackId, argv) => {
    expect(derive(stackId).devCommand).toEqual({
      argv: [...argv],
      workingDirectory: ".",
      source: "stack-default",
    });
  });

  it("refuses a start command that needs a shell", () => {
    expect(derive("sinatra", { startCommand: "bundle exec rake db:migrate && ruby app.rb" })).toEqual(
      { devCommand: null, problem: "the start command needs a shell to run" },
    );
  });

  it.each([
    ["docker", "it builds and runs from its Dockerfile"],
    ["static", "it is a static site with no dev script"],
    ["unknown", "no dev script and no start command was detected"],
  ] as const)("explains why a %s service has no dev command", (stackId, problem) => {
    expect(derive(stackId)).toEqual({ devCommand: null, problem });
  });
});
