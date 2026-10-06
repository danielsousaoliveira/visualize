import { posix } from "node:path";
import { LANGUAGE_DETECTORS } from "../core";
import { parseEnvFile } from "../core/env-file";
import { normalizeImageRef } from "../core/image-ref";
import type { ScanInfra, ScanInfraKind } from "./contract";
import type { ProjectReader } from "./local-reader";

export interface InfraComposeSource {
  name: string;
  image: string | null;
  environment: Record<string, string>;
}

export interface InfraSource {
  serviceId: string;
  directory: string | null;
  compose?: InfraComposeSource;
}

interface Endpoint {
  host: string | null;
  port: number | null;
}

interface Finding extends Endpoint {
  kind: ScanInfraKind;
  evidence: string;
}

interface Signal extends Finding {
  serviceIds: string[];
}

interface Provider {
  serviceId: string;
  name: string;
  evidence: string;
}

const KINDS: readonly ScanInfraKind[] = ["postgres", "mysql", "mongodb", "redis", "sqlite"];

const DEPENDENCY_KINDS: Readonly<Record<string, Readonly<Record<string, ScanInfraKind>>>> = {
  javascript: {
    pg: "postgres",
    postgres: "postgres",
    "pg-promise": "postgres",
    "@neondatabase/serverless": "postgres",
    mysql: "mysql",
    mysql2: "mysql",
    mongodb: "mongodb",
    mongoose: "mongodb",
    redis: "redis",
    ioredis: "redis",
    bullmq: "redis",
    "better-sqlite3": "sqlite",
    sqlite3: "sqlite",
  },
  python: {
    psycopg: "postgres",
    psycopg_binary: "postgres",
    psycopg2: "postgres",
    psycopg2_binary: "postgres",
    asyncpg: "postgres",
    pymysql: "mysql",
    mysqlclient: "mysql",
    pymongo: "mongodb",
    motor: "mongodb",
    redis: "redis",
  },
  go: {
    "github.com/lib/pq": "postgres",
    "github.com/jackc/pgx": "postgres",
    "github.com/go-sql-driver/mysql": "mysql",
    "go.mongodb.org/mongo-driver": "mongodb",
    "github.com/redis/go-redis": "redis",
    "github.com/go-redis/redis": "redis",
  },
  rust: {
    "tokio-postgres": "postgres",
  },
  ruby: {
    pg: "postgres",
    mysql2: "mysql",
    redis: "redis",
    sidekiq: "redis",
    sqlite3: "sqlite",
  },
};

const LOCKFILE_MANIFESTS = new Set(["gemfile.lock"]);

const SQLX_FEATURE_KINDS: Readonly<Record<string, ScanInfraKind>> = {
  postgres: "postgres",
  mysql: "mysql",
  sqlite: "sqlite",
};

const PRISMA_SCHEMAS = ["prisma/schema.prisma", "schema.prisma"];
const PRISMA_PROVIDER_KINDS: Readonly<Record<string, ScanInfraKind>> = {
  postgresql: "postgres",
  postgres: "postgres",
  mysql: "mysql",
  mongodb: "mongodb",
  sqlite: "sqlite",
};

const DRIZZLE_CONFIGS = ["drizzle.config.ts", "drizzle.config.js", "drizzle.config.mjs", "drizzle.config.cjs"];
const DRIZZLE_DIALECT_KINDS: Readonly<Record<string, ScanInfraKind>> = {
  postgresql: "postgres",
  mysql: "mysql",
  sqlite: "sqlite",
};

const DJANGO_SETTINGS = ["settings.py", "settings/__init__.py", "settings/base.py"];
const DJANGO_ENGINE_KINDS: Readonly<Record<string, ScanInfraKind>> = {
  postgresql: "postgres",
  postgresql_psycopg2: "postgres",
  mysql: "mysql",
  sqlite3: "sqlite",
};

const ENV_FILES = [".env", ".env.local", ".env.development", ".env.example"];

const SCHEME_KINDS: Readonly<Record<string, ScanInfraKind>> = {
  postgres: "postgres",
  postgresql: "postgres",
  mysql: "mysql",
  mongodb: "mongodb",
  redis: "redis",
  rediss: "redis",
  sqlite: "sqlite",
};

const SQLITE_ENV_KEY = /DATABASE|(?:^|_)DB(?:_|$)|SQLITE/i;
const SQLITE_ENV_VALUE = /^file:|\.(?:db|sqlite3?)$/i;
const HOST_PORT = /^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::(\d{1,5}))?$/;
const NO_ENDPOINT: Endpoint = { host: null, port: null };
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

const IMAGE_KINDS: ReadonlyArray<readonly [ScanInfraKind, RegExp]> = [
  ["postgres", /^(?:postgres|postgis\/postgis)(?::|$)/i],
  ["mysql", /^(?:mysql|mariadb|percona\/percona-server)(?::|$)/i],
  ["mongodb", /^(?:mongo|percona\/percona-server-mongodb)(?::|$)/i],
  ["redis", /^(?:redis|valkey\/valkey)(?::|$)|^redis\/(?!redisinsight(?::|$))/i],
];

export function imageInfraKind(image: string | null): ScanInfraKind | undefined {
  const ref = normalizeImageRef(image ?? "");
  return ref ? IMAGE_KINDS.find(([, pattern]) => pattern.test(ref))?.[0] : undefined;
}

export function urlEndpoint(value: string): Endpoint {
  const rest = value.slice(value.indexOf("://") + 3);
  const authorityEnd = rest.search(/[/?#]/);
  const authority = authorityEnd < 0 ? rest : rest.slice(0, authorityEnd);
  const path = authorityEnd < 0 ? "" : rest.slice(authorityEnd).split(/[?#]/)[0]!;
  if (path.includes("@")) return NO_ENDPOINT;
  const match = authority
    .slice(authority.lastIndexOf("@") + 1)
    .split(",")[0]!
    .match(HOST_PORT);
  if (!match) return NO_ENDPOINT;
  if (match[2] === undefined) return { host: match[1]!, port: null };
  const port = Number(match[2]);
  return port >= 1 && port <= 65535 ? { host: match[1]!, port } : NO_ENDPOINT;
}

export function envInfra(key: string, value: string): (Endpoint & { kind: ScanInfraKind }) | undefined {
  const scheme = value.match(/^([A-Za-z][A-Za-z0-9+.-]*):\/\//)?.[1]?.toLowerCase();
  const kind = scheme ? SCHEME_KINDS[scheme.split("+")[0]!] : undefined;
  if (kind && kind !== "sqlite") return { kind, ...urlEndpoint(value) };
  if (kind === "sqlite" || (SQLITE_ENV_KEY.test(key) && SQLITE_ENV_VALUE.test(value))) {
    return { kind: "sqlite", ...NO_ENDPOINT };
  }
  if (key === "REDIS_URL") return { kind: "redis", ...NO_ENDPOINT };
  return undefined;
}

function finding(kind: ScanInfraKind, evidence: string, endpoint = NO_ENDPOINT): Finding {
  return { kind, evidence, ...endpoint };
}

function manifestFindings(path: string, detectorId: string, deps: Record<string, string>): Finding[] {
  const table = DEPENDENCY_KINDS[detectorId] ?? {};
  return Object.keys(deps).flatMap((name) => {
    const kind = table[name];
    return kind ? [finding(kind, `dependency ${name} in ${path}`)] : [];
  });
}

function sqlxFindings(path: string, cargoToml: string): Finding[] {
  const inline = cargoToml.match(/^\s*sqlx\s*=\s*\{([^}]*)\}/m)?.[1];
  const table = cargoToml.match(/\[(?:workspace\.)?dependencies\.sqlx\]([\s\S]*?)(?=\n\[|$)/)?.[1];
  const features = (inline ?? table ?? "").match(/features\s*=\s*\[([^\]]*)\]/)?.[1] ?? "";
  return [...features.matchAll(/["']([^"']+)["']/g)].flatMap(([, feature]) => {
    const kind = SQLX_FEATURE_KINDS[feature!];
    return kind ? [finding(kind, `sqlx feature ${feature} in ${path}`)] : [];
  });
}

function prismaFindings(path: string, schema: string): Finding[] {
  const provider = schema.match(/datasource\s+\w+\s*\{[^}]*?\bprovider\s*=\s*"(\w+)"/)?.[1];
  const kind = provider ? PRISMA_PROVIDER_KINDS[provider] : undefined;
  return kind ? [finding(kind, `prisma provider ${provider} in ${path}`)] : [];
}

function drizzleFindings(path: string, config: string): Finding[] {
  const dialect = config.match(/\bdialect\s*:\s*["'](\w+)["']/)?.[1];
  const kind = dialect ? DRIZZLE_DIALECT_KINDS[dialect] : undefined;
  return kind ? [finding(kind, `drizzle dialect ${dialect} in ${path}`)] : [];
}

function djangoFindings(path: string, settings: string): Finding[] {
  return [...settings.matchAll(/["']ENGINE["']\s*:\s*["']django\.db\.backends\.(\w+)["']/g)].flatMap(
    ([, engine]) => {
      const kind = DJANGO_ENGINE_KINDS[engine!];
      return kind ? [finding(kind, `django engine ${engine} in ${path}`)] : [];
    },
  );
}

function envFindings(entries: Array<{ key: string; value: string }>, location: string): Finding[] {
  return entries.flatMap(({ key, value }) => {
    const detected = envInfra(key, value);
    return detected ? [finding(detected.kind, `env ${key} in ${location}`, detected)] : [];
  });
}

async function directoryFindings(reader: ProjectReader, directory: string): Promise<Finding[]> {
  const entries = await reader.listDirectory(directory === "." ? "" : directory);
  const files = new Map(
    entries.filter((entry) => entry.type !== "dir").map((entry) => [entry.name.toLowerCase(), entry.name]),
  );
  const subdirectories = entries.filter((entry) => entry.type === "dir").map((entry) => entry.name);
  const pathOf = (name: string) => posix.join(directory, name);
  const read = async (name: string) => {
    const content = await reader.readText(pathOf(name));
    return content === undefined ? [] : [{ path: pathOf(name), content }];
  };
  const readPresent = async (names: string[]) =>
    (await Promise.all(names.flatMap((name) => (files.has(name) ? [read(files.get(name)!)] : [])))).flat();
  const readAny = async (names: string[]) => (await Promise.all(names.map(read))).flat();

  const manifests = await Promise.all(
    LANGUAGE_DETECTORS.flatMap((detector) =>
      detector.manifestFiles
        .filter((manifest) => !LOCKFILE_MANIFESTS.has(manifest) && files.has(manifest))
        .map(async (manifest) => {
          const [file] = await read(files.get(manifest)!);
          if (!file) return [];
          return [
            ...manifestFindings(file.path, detector.id, detector.parseManifest(manifest, file.content)),
            ...(manifest === "cargo.toml" ? sqlxFindings(file.path, file.content) : []),
          ];
        }),
    ),
  );
  const djangoSettings = files.has("manage.py")
    ? await readAny(subdirectories.flatMap((dir) => DJANGO_SETTINGS.map((name) => `${dir}/${name}`)))
    : [];
  const envFiles = await readPresent(ENV_FILES);

  return [
    ...manifests.flat(),
    ...(await readAny(PRISMA_SCHEMAS)).flatMap(({ path, content }) => prismaFindings(path, content)),
    ...(await readPresent(DRIZZLE_CONFIGS)).flatMap(({ path, content }) => drizzleFindings(path, content)),
    ...djangoSettings.flatMap(({ path, content }) => djangoFindings(path, content)),
    ...envFiles.flatMap(({ path, content }) => envFindings(parseEnvFile(content), path)),
  ];
}

function unique<T>(values: T[]): T[] {
  return [...new Set(values)];
}

interface Group {
  provider?: Provider;
  endpoint: Endpoint;
  signals: Signal[];
}

function isLoopback(host: string): boolean {
  return LOOPBACK_HOSTS.has(host.toLowerCase());
}

function sharesService(group: Group, signal: Signal): boolean {
  return group.signals.some(
    (member) => member.host !== null && member.serviceIds.some((id) => signal.serviceIds.includes(id)),
  );
}

function groupSignals(signals: Signal[], providers: Provider[]): Group[] {
  const providerGroups: Group[] = providers.map((provider) => ({ provider, endpoint: NO_ENDPOINT, signals: [] }));
  const endpointGroups = new Map<string, Group>();

  for (const signal of signals.filter((candidate) => candidate.host !== null)) {
    const host = signal.host!;
    const key = `${host}:${signal.port ?? ""}`;
    const group =
      providerGroups.find((candidate) => candidate.provider!.name === host) ??
      (isLoopback(host) ? providerGroups[0] : undefined) ??
      endpointGroups.get(key) ??
      endpointGroups.set(key, { endpoint: NO_ENDPOINT, signals: [] }).get(key)!;
    if (group.endpoint.host === null) group.endpoint = { host, port: signal.port };
    group.signals.push(signal);
  }

  const groups = [...providerGroups, ...endpointGroups.values()];
  let fallback: Group | undefined;
  for (const signal of signals.filter((candidate) => candidate.host === null)) {
    const own = groups.filter((group) => sharesService(group, signal));
    if (own.length > 0) {
      for (const group of own) group.signals.push(signal);
      continue;
    }
    if (!fallback) {
      fallback = groups.length === 1 || providerGroups.length > 0 ? groups[0] : undefined;
      if (!fallback) {
        fallback = { endpoint: NO_ENDPOINT, signals: [] };
        groups.push(fallback);
      }
    }
    fallback.signals.push(signal);
  }

  for (const group of groups) {
    group.signals.sort((a, b) => signals.indexOf(a) - signals.indexOf(b));
  }
  return groups;
}

function toInfra(kind: ScanInfraKind, { provider, endpoint, signals }: Group): ScanInfra {
  return {
    kind,
    usedBy: unique(signals.flatMap((signal) => signal.serviceIds)).filter(
      (id) => id !== provider?.serviceId,
    ),
    providedBy: provider?.serviceId ?? null,
    evidence: unique([...(provider ? [provider.evidence] : []), ...signals.map((signal) => signal.evidence)]),
    host: endpoint.host,
    port: endpoint.port,
  };
}

export async function detectInfra(reader: ProjectReader, sources: InfraSource[]): Promise<ScanInfra[]> {
  const servicesByDirectory = new Map<string, string[]>([[".", []]]);
  for (const { serviceId, directory } of sources) {
    if (directory === null) continue;
    servicesByDirectory.set(directory, [...(servicesByDirectory.get(directory) ?? []), serviceId]);
  }

  const directorySignals = await Promise.all(
    [...servicesByDirectory].map(async ([directory, serviceIds]) =>
      (await directoryFindings(reader, directory)).map((found) => ({ ...found, serviceIds })),
    ),
  );
  const composeSignals = sources.flatMap(({ serviceId, compose }) =>
    compose
      ? envFindings(
          Object.entries(compose.environment).map(([key, value]) => ({ key, value })),
          `compose service ${compose.name}`,
        ).map((found) => ({ ...found, serviceIds: [serviceId] }))
      : [],
  );
  const signals: Signal[] = [...directorySignals.flat(), ...composeSignals];

  const providers = sources.flatMap(({ serviceId, compose }) => {
    const kind = compose && imageInfraKind(compose.image);
    return kind
      ? [{ kind, serviceId, name: compose.name, evidence: `image ${compose.image} in compose service ${compose.name}` }]
      : [];
  });

  return KINDS.flatMap((kind) =>
    groupSignals(
      signals.filter((signal) => signal.kind === kind),
      providers.filter((provider) => provider.kind === kind),
    ).map((group) => toInfra(kind, group)),
  );
}
