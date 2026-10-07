import { posix } from "node:path";
import { parseEnvFile } from "../core/env-file";
import type { ScanConnection, ScanConnectionKind, ScanInfra, ScanService } from "./contract";
import { EXAMPLE_ENV_FILES, REAL_ENV_FILES } from "./env-requirements";
import { envInfra, urlEndpoint } from "./infra";
import type { ProjectReader } from "./local-reader";

export interface ConnectionComposeSource {
  name: string;
  dependsOn: string[];
  environment: Record<string, string>;
  hostPorts: number[];
  envFiles: string[];
}

export interface ConnectionSource {
  serviceId: string;
  compose?: ConnectionComposeSource;
}

export interface ConnectionsResult {
  connections: ScanConnection[];
  warnings: string[];
}

interface EnvValue {
  key: string;
  value: string;
}

interface Node {
  id: string;
  name: string;
  port: number | null;
  compose?: ConnectionComposeSource;
}

const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1"]);
const URL_VALUE = /^[A-Za-z][A-Za-z0-9+.-]*:\/\/[^$]*$/;
const DEPENDENCY_FIELDS = ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"];

function isLoopback(host: string): boolean {
  return LOOPBACK_HOSTS.has(host.toLowerCase());
}

function address(host: string, port: number | null): string {
  return port === null ? host : `${host}:${port}`;
}

async function readEnvValues(reader: ProjectReader, paths: string[]): Promise<EnvValue[]> {
  const contents = await Promise.all(paths.map((path) => reader.readText(path)));
  return contents.flatMap((content) => (content === undefined ? [] : parseEnvFile(content)));
}

function envFilesOf(service: ScanService, compose: ConnectionComposeSource | undefined): string[] {
  if (compose) return compose.envFiles;
  return [...REAL_ENV_FILES, ...EXAMPLE_ENV_FILES].map((name) => posix.join(service.rootDirectory, name));
}

async function packageJsonOf(
  reader: ProjectReader,
  service: ScanService,
): Promise<Record<string, unknown> | undefined> {
  return service.kind === "app"
    ? await reader.readJson(posix.join(service.rootDirectory, "package.json"))
    : undefined;
}

function dependencyNames(packageJson: Record<string, unknown> | undefined): string[] {
  return DEPENDENCY_FIELDS.flatMap((field) => {
    const deps = packageJson?.[field];
    return deps && typeof deps === "object" ? Object.keys(deps) : [];
  });
}

function infraAt(infra: ScanInfra[], host: string, port: number | null): ScanInfra[] {
  return infra.filter(
    (entry) => entry.host?.toLowerCase() === host.toLowerCase() && entry.port === port,
  );
}

type Resolution =
  | { kind: "target"; id: string }
  | { kind: "none" }
  | { kind: "unresolved"; address: string }
  | { kind: "ambiguous"; address: string; ids: string[] };

const NONE: Resolution = { kind: "none" };

function single(address: string, ids: string[], otherwise: () => Resolution): Resolution {
  if (ids.length === 1) return { kind: "target", id: ids[0]! };
  if (ids.length > 1) return { kind: "ambiguous", address, ids };
  return otherwise();
}

function hostName(node: Node): string {
  return (node.compose?.name ?? node.name).toLowerCase();
}

function resolveUrl(source: Node, nodes: Node[], infra: ScanInfra[], { key, value }: EnvValue): Resolution {
  const { host, port } = urlEndpoint(value);
  if (host === null) return NONE;
  const target = address(host, port);
  const unresolved: Resolution = { kind: "unresolved", address: target };
  const others = nodes.filter((node) => node.id !== source.id);
  const infraIds = () => infraAt(infra, host, port).map((entry) => entry.id);

  if (isLoopback(host) && source.compose) return single(target, infraIds(), () => NONE);
  if (!isLoopback(host)) {
    const named = others.filter((node) => hostName(node) === host.toLowerCase()).map((node) => node.id);
    const expectedInScan = !host.includes(".") || envInfra(key, value) !== undefined;
    return single(target, named, () => single(target, infraIds(), () => (expectedInScan ? unresolved : NONE)));
  }

  if (port !== null && source.port === port) return NONE;
  const listening = others
    .filter((node) => port !== null && (node.compose ? node.compose.hostPorts.includes(port) : node.port === port))
    .map((node) => node.id);
  return single(target, listening, () =>
    single(target, infraIds(), () => unresolved),
  );
}

function resolutionWarning(service: string, key: string, resolution: Resolution): string | undefined {
  switch (resolution.kind) {
    case "unresolved":
      return `Service "${service}": ${key} points at ${resolution.address}, which matches nothing in the scan; the connection is left out.`;
    case "ambiguous":
      return `Service "${service}": ${key} points at ${resolution.address}, which matches ${resolution.ids.join(", ")}; the connection is left out.`;
    default:
      return undefined;
  }
}

export async function detectConnections(
  reader: ProjectReader,
  services: ScanService[],
  sources: ConnectionSource[],
  infra: ScanInfra[],
): Promise<ConnectionsResult> {
  const composeById = new Map(sources.map(({ serviceId, compose }) => [serviceId, compose]));
  const nodes: Node[] = services.map((service) => ({
    id: service.id,
    name: service.name,
    port: service.port,
    compose: composeById.get(service.id),
  }));
  const packageJsons = await Promise.all(services.map((service) => packageJsonOf(reader, service)));
  const serviceByPackage = new Map<string, string>();
  packageJsons.forEach((packageJson, index) => {
    const name = packageJson?.name;
    if (typeof name === "string" && name) serviceByPackage.set(name, services[index]!.id);
  });

  const connections: ScanConnection[] = [];
  const seen = new Set<string>();
  const warnings: string[] = [];
  const connect = (from: string, to: string, kind: ScanConnectionKind, label: string) => {
    const key = JSON.stringify([from, to, kind]);
    if (from === to || seen.has(key)) return;
    seen.add(key);
    connections.push({ from, to, kind, label });
  };

  for (const [index, service] of services.entries()) {
    const node = nodes[index]!;
    const compose = node.compose;

    for (const dependency of compose?.dependsOn ?? []) {
      const target = nodes.find((candidate) => candidate.compose?.name === dependency);
      if (!target) {
        warnings.push(
          `Service "${node.name}": depends_on ${dependency} matches no compose service; the connection is left out.`,
        );
        continue;
      }
      connect(node.id, target.id, "depends_on", "depends_on");
    }

    const envValues = [
      ...Object.entries(compose?.environment ?? {}).map(([key, value]) => ({ key, value })),
      ...(await readEnvValues(reader, envFilesOf(service, compose))),
    ];
    for (const envValue of envValues) {
      if (!URL_VALUE.test(envValue.value)) continue;
      const resolution = resolveUrl(node, nodes, infra, envValue);
      if (resolution.kind === "target") connect(node.id, resolution.id, "env-url", envValue.key);
      const warning = resolutionWarning(node.name, envValue.key, resolution);
      if (warning && !warnings.includes(warning)) warnings.push(warning);
    }

    for (const entry of infra.filter(({ usedBy }) => usedBy.includes(node.id))) {
      connect(node.id, entry.id, "uses-infra", entry.kind);
    }

    for (const dependency of dependencyNames(packageJsons[index])) {
      const target = serviceByPackage.get(dependency);
      if (target) connect(node.id, target, "workspace-dep", dependency);
    }
  }

  return { connections, warnings };
}
