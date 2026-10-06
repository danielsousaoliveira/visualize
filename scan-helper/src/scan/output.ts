import { posix } from "node:path";
import type { ComposeService } from "../engine/compose-parser";
import { buildProjectRootSnapshot, type MonorepoApp } from "../engine/project-root-detector";
import type { StackResult } from "../engine/stack-detector";
import {
  SCHEMA_VERSION,
  type ScanComposeService,
  type ScanPortMapping,
  type ScanResult,
  type ScanService,
} from "./contract";
import type { ProjectReader } from "./local-reader";
import { readProjectSnapshot, type ProjectInfo } from "./resolve";

const DOCKERFILE = "Dockerfile";

function toRelativeDirectory(path: string): string {
  return posix.normalize(path || ".").replace(/(.)\/+$/, "$1");
}

function isLocalPath(path: string): boolean {
  return !path.includes("://") && !path.includes("$") && !path.startsWith("git@");
}

function isInsideRoot(relativePath: string): boolean {
  return relativePath !== ".." && !relativePath.startsWith("../") && !posix.isAbsolute(relativePath);
}

function splitOutsideBrackets(value: string): string[] {
  const parts = [""];
  let depth = 0;
  for (const char of value) {
    if (char === "{" || char === "[") depth += 1;
    if ((char === "}" || char === "]") && depth > 0) depth -= 1;
    if (char === ":" && depth === 0) parts.push("");
    else parts[parts.length - 1] += char;
  }
  return parts;
}

const HOST_ADDRESS = /^(?:\d{1,3}(?:\.\d{1,3}){3}|\[[0-9A-Fa-f:.]+\]|\$\{[^}]+\})$/;

function mapping(host: string, container: string): ScanPortMapping | undefined {
  return container ? { host: host || null, container } : undefined;
}

export function toPortMapping(spec: string): ScanPortMapping | undefined {
  const parts = splitOutsideBrackets(spec.replace(/\/(?:tcp|udp|sctp)$/i, ""));
  switch (parts.length) {
    case 1:
      return mapping("", parts[0]!);
    case 2:
      return mapping(parts[0]!, parts[1]!);
    case 3:
      return HOST_ADDRESS.test(parts[0]!) ? mapping(parts[1]!, parts[2]!) : undefined;
    default:
      return undefined;
  }
}

function portMappings(service: ComposeService): ScanPortMapping[] {
  return service.ports.flatMap((spec) => toPortMapping(spec) ?? []);
}

function containerPort(ports: ScanPortMapping[]): number | null {
  const first = ports[0]?.container;
  return first && /^\d+$/.test(first) ? Number(first) : null;
}

function knownPackageManager(packageManager: string): string | null {
  return packageManager === "unknown" ? null : packageManager;
}

async function fileExists(reader: ProjectReader, path: string): Promise<boolean> {
  return (await reader.readText(path)) !== undefined;
}

async function detectStackIn(
  reader: ProjectReader,
  directory: string,
): Promise<StackResult | undefined> {
  const snapshot = await readProjectSnapshot(reader, directory === "." ? "" : directory);
  return snapshot.files.length > 0 ? buildProjectRootSnapshot(snapshot).stack : undefined;
}

function serviceRecipe(source: {
  stack: string;
  category: string;
  packageManager: string;
  installCommand: string;
  buildCommand: string;
  startCommand: string;
}) {
  return {
    stackId: source.stack,
    category: source.category,
    packageManager: knownPackageManager(source.packageManager),
    installCommand: source.installCommand || null,
    buildCommand: source.buildCommand || null,
    startCommand: source.startCommand || null,
  };
}

async function appService(
  reader: ProjectReader,
  id: string,
  name: string,
  source: MonorepoApp | ProjectInfo,
): Promise<ScanService> {
  const rootDirectory = toRelativeDirectory(source.rootDirectory);
  return {
    id,
    name,
    kind: "app",
    rootDirectory,
    ...serviceRecipe(source),
    port: source.port,
    hasDockerfile: await fileExists(reader, posix.join(rootDirectory, DOCKERFILE)),
  };
}

function buildContext(service: ComposeService, composeDirectory: string): string | null {
  if (!service.build) return null;
  return isLocalPath(service.build)
    ? toRelativeDirectory(posix.join(composeDirectory, service.build))
    : service.build;
}

async function composeService(
  reader: ProjectReader,
  service: ComposeService,
  composeDirectory: string,
): Promise<ScanService> {
  const context = buildContext(service, composeDirectory);
  const readable = context !== null && isLocalPath(context) && isInsideRoot(context);
  const stack = readable ? await detectStackIn(reader, context) : undefined;
  const dockerfile = posix.join(context ?? ".", service.dockerfile ?? DOCKERFILE);
  return {
    id: `compose:${service.name}`,
    name: service.name,
    kind: "compose",
    rootDirectory: readable ? context : composeDirectory,
    ...(stack
      ? serviceRecipe(stack)
      : {
          stackId: null,
          category: null,
          packageManager: null,
          installCommand: null,
          buildCommand: null,
          startCommand: null,
        }),
    port: containerPort(portMappings(service)),
    hasDockerfile: readable && (await fileExists(reader, dockerfile)),
  };
}

function toComposeService(service: ComposeService, composeDirectory: string): ScanComposeService {
  return {
    name: service.name,
    image: service.image ?? null,
    buildContext: buildContext(service, composeDirectory),
    ports: portMappings(service),
    dependsOn: service.dependsOn,
    environment: Object.keys(service.environment),
  };
}

function collectWarnings(info: ProjectInfo): string[] {
  const ignoredComposeFiles = (info.composeFiles ?? []).filter(
    (file) => file !== info.composeFileRead,
  );
  return [
    ...(info.composeFileRead && ignoredComposeFiles.length > 0
      ? [`Only ${info.composeFileRead} was read; ${ignoredComposeFiles.join(", ")} ignored.`]
      : []),
    ...(info.missingRequiredEnv ?? []).map(
      ({ variable }) => `Compose variable ${variable} is required but has no value.`,
    ),
    ...(info.services ?? []).flatMap((service) =>
      service.ports
        .filter((spec) => toPortMapping(spec) === undefined)
        .map((spec) => `Service "${service.name}": port "${spec}" was not understood and is left out.`),
    ),
    ...(info.unsupportedCompose ?? []).map(
      ({ service, reason }) => `Service "${service}": ${reason}`,
    ),
  ];
}

async function collectServices(
  info: ProjectInfo,
  reader: ProjectReader,
  composeDirectory: string,
): Promise<ScanService[]> {
  if (info.services) {
    return Promise.all(
      info.services.map((service) => composeService(reader, service, composeDirectory)),
    );
  }
  if (info.monorepoApps) {
    return Promise.all(
      info.monorepoApps.map((app) =>
        appService(reader, toRelativeDirectory(app.rootDirectory), app.name, app),
      ),
    );
  }
  return [
    await appService(reader, toRelativeDirectory(info.rootDirectory), info.repository.name, info),
  ];
}

export async function toScanResult(info: ProjectInfo, reader: ProjectReader): Promise<ScanResult> {
  const composeDirectory = toRelativeDirectory(posix.dirname(info.composeFileRead ?? "."));
  return {
    schemaVersion: SCHEMA_VERSION,
    project: {
      name: info.repository.name,
      rootPath: info.repository.full_name,
      gitBranch: info.repository.selected_branch ?? null,
      type: info.projectType,
    },
    services: await collectServices(info, reader, composeDirectory),
    composeFiles: info.composeFiles ?? [],
    composeServices: (info.services ?? []).map((service) =>
      toComposeService(service, composeDirectory),
    ),
    envRequirements: [],
    infra: [],
    connections: [],
    warnings: collectWarnings(info),
  };
}
