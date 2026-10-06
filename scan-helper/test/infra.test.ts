import { afterAll, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { envInfra, imageInfraKind, urlEndpoint } from "../src/scan/infra";
import { scanFolder } from "../src/scan/scan-folder";

const FIXTURES_DIR = fileURLToPath(new URL("../fixtures/scan", import.meta.url));
const workspace = mkdtempSync(join(tmpdir(), "visualize-infra-"));

afterAll(() => rmSync(workspace, { recursive: true, force: true }));

function folder(name: string, files: Record<string, string>): string {
  const root = join(workspace, name);
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(join(root, path, ".."), { recursive: true });
    writeFileSync(join(root, path), content);
  }
  return root;
}

async function infraOf(root: string) {
  return (await scanFolder(root)).infra;
}

const NODE_APP = JSON.stringify({ name: "svc", scripts: { start: "node server.js" } });

describe("infra from the scan fixtures", () => {
  it("finds Postgres from a pg dependency without a compose file", async () => {
    expect(await infraOf(join(FIXTURES_DIR, "infra-node-pg"))).toEqual([
      {
        kind: "postgres",
        usedBy: ["."],
        providedBy: null,
        evidence: ["dependency pg in package.json"],
        host: null,
        port: null,
      },
    ]);
  });

  it("takes host and port from REDIS_URL in .env", async () => {
    const [redis] = await infraOf(join(FIXTURES_DIR, "infra-redis-env"));
    expect(redis).toMatchObject({ kind: "redis", usedBy: ["."], host: "localhost", port: 6380 });
    expect(redis!.evidence).toEqual(["env REDIS_URL in .env"]);
  });

  it("links a pg dependency to the compose Postgres instead of adding a second entry", async () => {
    expect(await infraOf(join(FIXTURES_DIR, "infra-compose-pg"))).toEqual([
      {
        kind: "postgres",
        usedBy: ["compose:api"],
        providedBy: "compose:db",
        evidence: ["image postgres:16 in compose service db", "dependency pg in api/package.json"],
        host: null,
        port: null,
      },
    ]);
  });

  it("finds MySQL from a Prisma schema", async () => {
    const infra = await infraOf(join(FIXTURES_DIR, "infra-prisma-mysql"));
    expect(infra.map(({ kind, evidence }) => ({ kind, evidence }))).toEqual([
      { kind: "mysql", evidence: ["prisma provider mysql in prisma/schema.prisma"] },
    ]);
  });

  it("finds MongoDB from pymongo", async () => {
    const infra = await infraOf(join(FIXTURES_DIR, "infra-python-mongo"));
    expect(infra.map(({ kind, evidence }) => ({ kind, evidence }))).toEqual([
      { kind: "mongodb", evidence: ["dependency pymongo in requirements.txt"] },
    ]);
  });

  it("finds SQLite from Django's default settings", async () => {
    const infra = await infraOf(join(FIXTURES_DIR, "django-uv"));
    expect(infra.map(({ kind, evidence }) => ({ kind, evidence }))).toEqual([
      { kind: "sqlite", evidence: ["django engine sqlite3 in mysite/settings.py"] },
    ]);
  });

  it("reads a compose service's env URL and links it to the matching compose service", async () => {
    const infra = await infraOf(join(FIXTURES_DIR, "compose-env"));
    expect(infra.map(({ kind, usedBy, providedBy, host, port }) => ({ kind, usedBy, providedBy, host, port }))).toEqual([
      { kind: "postgres", usedBy: ["compose:api"], providedBy: "compose:db", host: "db", port: 5432 },
      { kind: "redis", usedBy: [], providedBy: "compose:cache", host: null, port: null },
    ]);
  });
});

describe("env URL credentials stay out of the output", () => {
  it("keeps host and port and drops user, password and database", async () => {
    const root = folder("credentials", {
      "package.json": NODE_APP,
      ".env": "DATABASE_URL=postgres://admin:s3cret@db:5432/app\n",
    });
    const output = JSON.stringify(await scanFolder(root));
    const result = JSON.parse(output);
    expect(result.infra).toEqual([
      {
        kind: "postgres",
        usedBy: ["."],
        providedBy: null,
        evidence: ["env DATABASE_URL in .env"],
        host: "db",
        port: 5432,
      },
    ]);
    expect(output).toContain('"db"');
    expect(output).toContain("5432");
    expect(output).not.toContain("admin");
    expect(output).not.toContain("s3cret");
    const withoutEnumApp = output.replace(/"(?:kind|type)":"app"/g, "");
    expect(withoutEnumApp).not.toMatch(/\bapp\b/);
  });

  it("gives up on the host when the authority is ambiguous", () => {
    expect(urlEndpoint("postgres://admin:pa/ss@db:5432/app")).toEqual({ host: null, port: null });
  });

  it.each(["postgres://db:99999/x", "postgres://db:0/x", "postgres://db:abc/x", "postgres://db:/x"])(
    "rejects the malformed port in %s",
    (value) => {
      expect(urlEndpoint(value)).toEqual({ host: null, port: null });
    },
  );
});

describe("other ecosystems", () => {
  it("reads Go modules", async () => {
    const root = folder("go", {
      "go.mod": [
        "module example.com/svc",
        "",
        "go 1.22",
        "",
        "require (",
        "\tgithub.com/jackc/pgx/v5 v5.7.1",
        "\tgithub.com/redis/go-redis/v9 v9.7.0",
        "\tgo.mongodb.org/mongo-driver v1.17.1",
        "\tgithub.com/go-sql-driver/mysql v1.8.1",
        ")",
      ].join("\n"),
      "main.go": "package main\n\nfunc main() {}\n",
    });
    const infra = await infraOf(root);
    expect(infra.map(({ kind, evidence }) => ({ kind, evidence }))).toEqual([
      { kind: "postgres", evidence: ["dependency github.com/jackc/pgx in go.mod"] },
      { kind: "mysql", evidence: ["dependency github.com/go-sql-driver/mysql in go.mod"] },
      { kind: "mongodb", evidence: ["dependency go.mongodb.org/mongo-driver in go.mod"] },
      { kind: "redis", evidence: ["dependency github.com/redis/go-redis in go.mod"] },
    ]);
  });

  it("reads sqlx features and tokio-postgres from Cargo.toml", async () => {
    const root = folder("rust", {
      "Cargo.toml": [
        "[package]",
        'name = "svc"',
        'version = "0.1.0"',
        "",
        "[dependencies]",
        'sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "sqlite"] }',
        'tokio-postgres = "0.7"',
      ].join("\n"),
      "src/main.rs": "fn main() {}\n",
    });
    const infra = await infraOf(root);
    expect(infra.map(({ kind, evidence }) => ({ kind, evidence }))).toEqual([
      {
        kind: "postgres",
        evidence: ["dependency tokio-postgres in Cargo.toml", "sqlx feature postgres in Cargo.toml"],
      },
      { kind: "sqlite", evidence: ["sqlx feature sqlite in Cargo.toml"] },
    ]);
  });

  it("reads a sqlx dependency table", async () => {
    const root = folder("rust-table", {
      "Cargo.toml": '[package]\nname = "svc"\n\n[dependencies.sqlx]\nversion = "0.8"\nfeatures = ["mysql"]\n',
      "src/main.rs": "fn main() {}\n",
    });
    expect((await infraOf(root)).map(({ kind }) => kind)).toEqual(["mysql"]);
  });

  it("reads gems from the Gemfile", async () => {
    const root = folder("ruby", {
      Gemfile: 'source "https://rubygems.org"\ngem "pg"\ngem "sidekiq"\n# gem "mysql2"\n',
    });
    const infra = await infraOf(root);
    expect(infra.map(({ kind, evidence }) => ({ kind, evidence }))).toEqual([
      { kind: "postgres", evidence: ["dependency pg in Gemfile"] },
      { kind: "redis", evidence: ["dependency sidekiq in Gemfile"] },
    ]);
  });

  it("reads Python names from pyproject.toml", async () => {
    const root = folder("python", {
      "pyproject.toml": '[project]\nname = "svc"\ndependencies = ["psycopg[binary]>=3.2", "redis>=5"]\n',
      "main.py": "print('hi')\n",
    });
    expect((await infraOf(root)).map(({ kind }) => kind)).toEqual(["postgres", "redis"]);
  });

  it("reads Node drivers and a Drizzle dialect", async () => {
    const root = folder("node-mix", {
      "package.json": JSON.stringify({
        name: "svc",
        scripts: { start: "node server.js" },
        dependencies: { "drizzle-orm": "^0.36.0", "@neondatabase/serverless": "^0.10.0", ioredis: "^5.4.0" },
        devDependencies: { "better-sqlite3": "^11.0.0", mongoose: "^8.0.0" },
      }),
      "drizzle.config.ts": 'export default { dialect: "postgresql", schema: "./schema.ts" };\n',
    });
    const infra = await infraOf(root);
    expect(infra.map(({ kind, evidence }) => ({ kind, evidence }))).toEqual([
      {
        kind: "postgres",
        evidence: [
          "dependency @neondatabase/serverless in package.json",
          "drizzle dialect postgresql in drizzle.config.ts",
        ],
      },
      { kind: "mongodb", evidence: ["dependency mongoose in package.json"] },
      { kind: "redis", evidence: ["dependency ioredis in package.json"] },
      { kind: "sqlite", evidence: ["dependency better-sqlite3 in package.json"] },
    ]);
  });

  it("attributes each workspace app's signals to that app", async () => {
    const root = folder("monorepo", {
      "package.json": JSON.stringify({ name: "mono", private: true, workspaces: ["apps/*"] }),
      "apps/api/package.json": JSON.stringify({
        name: "api",
        scripts: { start: "node server.js" },
        dependencies: { pg: "^8.0.0" },
      }),
      "apps/worker/package.json": JSON.stringify({
        name: "worker",
        scripts: { start: "node worker.js" },
        dependencies: { bullmq: "^5.0.0", pg: "^8.0.0" },
      }),
    });
    const infra = await infraOf(root);
    expect(infra.map(({ kind, usedBy, evidence }) => ({ kind, usedBy, evidence }))).toEqual([
      {
        kind: "postgres",
        usedBy: ["apps/api", "apps/worker"],
        evidence: ["dependency pg in apps/api/package.json", "dependency pg in apps/worker/package.json"],
      },
      { kind: "redis", usedBy: ["apps/worker"], evidence: ["dependency bullmq in apps/worker/package.json"] },
    ]);
  });

  function compose(services: Record<string, string[]>): string {
    return [
      "services:",
      ...Object.entries(services).flatMap(([name, lines]) => [`  ${name}:`, ...lines.map((line) => `    ${line}`)]),
    ].join("\n");
  }

  function postgresUser(host: string): string[] {
    return ["image: node:22", "environment:", `  DATABASE_URL: postgres://u:p@${host}:5432/x`];
  }

  async function links(root: string) {
    return (await infraOf(root)).map(({ kind, usedBy, providedBy, host, port }) => ({
      kind,
      usedBy,
      providedBy,
      host,
      port,
    }));
  }

  it("keeps an external database URL apart from the compose services of that kind", async () => {
    const root = folder("external-postgres", {
      "docker-compose.yml": compose({
        api: postgresUser("prod.db.example.com"),
        primary: ["image: postgres:16"],
        analytics: ["image: postgres:16"],
      }),
    });
    expect(await infraOf(root)).toEqual([
      {
        kind: "postgres",
        usedBy: [],
        providedBy: "compose:primary",
        evidence: ["image postgres:16 in compose service primary"],
        host: null,
        port: null,
      },
      {
        kind: "postgres",
        usedBy: [],
        providedBy: "compose:analytics",
        evidence: ["image postgres:16 in compose service analytics"],
        host: null,
        port: null,
      },
      {
        kind: "postgres",
        usedBy: ["compose:api"],
        providedBy: null,
        evidence: ["env DATABASE_URL in compose service api"],
        host: "prod.db.example.com",
        port: 5432,
      },
    ]);
  });

  it.each([
    ["external first", ["prod.example.com", "db"]],
    ["compose first", ["db", "prod.example.com"]],
  ])("gives local and external endpoints their own entries, %s", async (_order, [apiHost, workerHost]) => {
    const root = folder(`mixed-${apiHost}`, {
      "docker-compose.yml": compose({
        api: postgresUser(apiHost!),
        worker: postgresUser(workerHost!),
        db: ["image: postgres:16"],
      }),
    });
    const local = apiHost === "db" ? "compose:api" : "compose:worker";
    const external = apiHost === "db" ? "compose:worker" : "compose:api";
    expect(await links(root)).toEqual([
      { kind: "postgres", usedBy: [local], providedBy: "compose:db", host: "db", port: 5432 },
      { kind: "postgres", usedBy: [external], providedBy: null, host: "prod.example.com", port: 5432 },
    ]);
  });

  it("gives each distinct external endpoint its own entry", async () => {
    const root = folder("two-external", {
      "docker-compose.yml": compose({
        api: postgresUser("a.example.com"),
        worker: postgresUser("b.example.com"),
        jobs: postgresUser("a.example.com"),
      }),
    });
    expect(await links(root)).toEqual([
      { kind: "postgres", usedBy: ["compose:api", "compose:jobs"], providedBy: null, host: "a.example.com", port: 5432 },
      { kind: "postgres", usedBy: ["compose:worker"], providedBy: null, host: "b.example.com", port: 5432 },
    ]);
  });

  it("puts a dependency with its own service's endpoint, and the rest with the compose provider", async () => {
    const root = folder("dependency-grouping", {
      "docker-compose.yml": compose({
        api: ["build: ./api", "environment:", "  DATABASE_URL: postgres://u:p@prod.example.com:5432/x"],
        worker: ["build: ./worker"],
        db: ["image: postgres:16"],
      }),
      "api/package.json": JSON.stringify({ name: "api", scripts: { start: "node a.js" }, dependencies: { pg: "^8.0.0" } }),
      "worker/package.json": JSON.stringify({ name: "worker", scripts: { start: "node w.js" }, dependencies: { pg: "^8.0.0" } }),
    });
    expect(
      (await infraOf(root)).map(({ usedBy, providedBy, evidence }) => ({ usedBy, providedBy, evidence })),
    ).toEqual([
      {
        usedBy: ["compose:worker"],
        providedBy: "compose:db",
        evidence: ["image postgres:16 in compose service db", "dependency pg in worker/package.json"],
      },
      {
        usedBy: ["compose:api"],
        providedBy: null,
        evidence: ["dependency pg in api/package.json", "env DATABASE_URL in compose service api"],
      },
    ]);
  });

  it("links a localhost URL to the compose service that publishes the kind", async () => {
    const root = folder("local-postgres", {
      "package.json": NODE_APP,
      ".env": "DATABASE_URL=postgres://u:p@localhost:5432/x\n",
      "docker-compose.yml": compose({ db: ["image: postgres:16", 'ports: ["5432:5432"]'] }),
    });
    expect(await links(root)).toEqual([
      { kind: "postgres", usedBy: [], providedBy: "compose:db", host: "localhost", port: 5432 },
    ]);
  });

  it("links a URL to the compose service its host names when two provide a kind", async () => {
    const root = folder("two-postgres", {
      "docker-compose.yml": compose({
        api: postgresUser("analytics"),
        primary: ["image: postgres:16"],
        analytics: ["image: docker.io/library/postgres:16"],
      }),
    });
    expect(await links(root)).toEqual([
      { kind: "postgres", usedBy: [], providedBy: "compose:primary", host: null, port: null },
      { kind: "postgres", usedBy: ["compose:api"], providedBy: "compose:analytics", host: "analytics", port: 5432 },
    ]);
  });

  it("leaves a dependency unlinked when two compose services provide the kind", async () => {
    const root = folder("two-postgres-dependency", {
      "docker-compose.yml": compose({
        api: ["build: ./api"],
        primary: ["image: postgres:16"],
        analytics: ["image: postgres:16"],
      }),
      "api/package.json": JSON.stringify({ name: "api", scripts: { start: "node a.js" }, dependencies: { pg: "^8.0.0" } }),
    });
    expect(await links(root)).toEqual([
      { kind: "postgres", usedBy: [], providedBy: "compose:primary", host: null, port: null },
      { kind: "postgres", usedBy: [], providedBy: "compose:analytics", host: null, port: null },
      { kind: "postgres", usedBy: ["compose:api"], providedBy: null, host: null, port: null },
    ]);
  });

  it("leaves a URL with an unresolved host unlinked when two compose services provide the kind", async () => {
    const root = folder("two-postgres-unresolved", {
      "docker-compose.yml": compose({
        api: ["image: node:22", "environment:", "  DATABASE_URL: postgres://u:p@$${DB_HOST}:5432/x"],
        primary: ["image: postgres:16"],
        analytics: ["image: postgres:16"],
      }),
    });
    expect((await links(root)).find(({ usedBy }) => usedBy.includes("compose:api"))).toEqual({
      kind: "postgres",
      usedBy: ["compose:api"],
      providedBy: null,
      host: null,
      port: null,
    });
  });

  it("links a localhost URL to the compose service publishing its port when two provide the kind", async () => {
    const root = folder("two-postgres-localhost", {
      "package.json": NODE_APP,
      ".env": "DATABASE_URL=postgres://u:p@localhost:5433/x\n",
      "docker-compose.yml": compose({
        primary: ["image: postgres:16", 'ports: ["5432:5432"]'],
        analytics: ["image: postgres:16", 'ports: ["5433:5432"]'],
      }),
    });
    expect(await links(root)).toEqual([
      { kind: "postgres", usedBy: [], providedBy: "compose:primary", host: null, port: null },
      { kind: "postgres", usedBy: [], providedBy: "compose:analytics", host: "localhost", port: 5433 },
    ]);
  });

  it("leaves a localhost URL unlinked when no compose service publishes its port", async () => {
    const root = folder("two-postgres-localhost-unpublished", {
      "package.json": NODE_APP,
      ".env": "DATABASE_URL=postgres://u:p@localhost:5440/x\n",
      "docker-compose.yml": compose({
        primary: ["image: postgres:16", 'ports: ["5432:5432"]'],
        analytics: ["image: postgres:16", 'ports: ["5433:5432"]'],
      }),
    });
    expect((await links(root)).filter(({ providedBy }) => providedBy === null)).toEqual([
      { kind: "postgres", usedBy: [], providedBy: null, host: "localhost", port: 5440 },
    ]);
  });
});

describe("env values", () => {
  it.each([
    ["DATABASE_URL", "postgresql://db.internal/app", { kind: "postgres", host: "db.internal", port: null }],
    ["DB", "postgresql+asyncpg://u:p@localhost:5433/x", { kind: "postgres", host: "localhost", port: 5433 }],
    ["MYSQL", "mysql://root@127.0.0.1:3306", { kind: "mysql", host: "127.0.0.1", port: 3306 }],
    ["MONGO_URI", "mongodb+srv://u:p@cluster0.example.net/x", { kind: "mongodb", host: "cluster0.example.net", port: null }],
    ["MONGO_URI", "mongodb://u:p@h1:27017,h2:27018/x", { kind: "mongodb", host: "h1", port: 27017 }],
    ["CACHE", "rediss://:p@[::1]:6390/0", { kind: "redis", host: "[::1]", port: 6390 }],
    ["REDIS_URL", "", { kind: "redis", host: null, port: null }],
    ["REDIS_URL", "${REDIS}", { kind: "redis", host: null, port: null }],
    ["DATABASE_URL", "postgres://${DB_HOST}:5432/x", { kind: "postgres", host: null, port: null }],
    ["DATABASE_URL", "file:./dev.db", { kind: "sqlite", host: null, port: null }],
    ["SQLITE_PATH", "data/app.sqlite3", { kind: "sqlite", host: null, port: null }],
    ["DATABASE_URL", "sqlite:///data.db", { kind: "sqlite", host: null, port: null }],
  ])("%s=%s", (key, value, expected) => {
    expect(envInfra(key, value)).toEqual(expected as ReturnType<typeof envInfra>);
  });

  it.each([
    ["LOG_FILE", "file:/tmp/app.log"],
    ["API_URL", "https://api.example.com"],
    ["DATABASE_URL", ""],
    ["CACHE_DB", "3"],
  ])("ignores %s=%s", (key, value) => {
    expect(envInfra(key, value)).toBeUndefined();
  });
});

describe("compose images", () => {
  it.each([
    ["postgres", "postgres"],
    ["postgres:16-alpine", "postgres"],
    ["postgres@sha256:" + "a".repeat(64), "postgres"],
    ["docker.io/library/postgres:16", "postgres"],
    ["postgis/postgis:16-3.4", "postgres"],
    ["mariadb:11", "mysql"],
    ["mongo:7", "mongodb"],
    ["redis/redis-stack:latest", "redis"],
    ["valkey/valkey:8", "redis"],
  ])("%s is %s", (image, kind) => {
    expect(imageInfraKind(image)).toBe(kind as ReturnType<typeof imageInfraKind>);
  });

  it.each(["acme/mysql-proxy", "postgres-exporter:1", "someorg/postgres:16", "redis/redisinsight:2", "nginx", null])(
    "%s is no database",
    (image) => {
      expect(imageInfraKind(image)).toBeUndefined();
    },
  );
});
