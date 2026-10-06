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

type ServiceWithoutDevCommand = Omit<ScanService, "devCommand">;

interface ScannedService {
  service: ScanService;
  warning?: string;
  infraSource: InfraSource;
  envSource: EnvSource;
}
import type { ProjectReader } from "./local-reader";
import { readProjectSnapshot, type ProjectInfo } from "./resolve";
import { deriveDevCommand } from "./dev-command";
import { detectInfra, type InfraSource } from "./infra";
import { detectEnvRequirements, type EnvComposeFile, type EnvSource } from "./env-requirements";
import type { StackId } from "../core";

const DOCKERFILE = "Dockerfile";
const JS_PACKAGE_MANAGERS = new Set(["npm", "pnpm", "yarn", "bun"]);
const GRADLE_BUILD_FILES = ["build.gradle.kts", "build.gradle"];
const JS_LOCKFILES = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb"];

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

async function packageScripts(
  reader: ProjectReader,
  rootDirectory: string,
): Promise<Record<string, unknown>> {
  const packageJson = await reader.readJson(posix.join(rootDirectory, "package.json"));
  const scripts = packageJson?.scripts;
  return scripts && typeof scripts === "object" ? (scripts as Record<string, unknown>) : {};
}

function devPackageManager(
  service: ServiceWithoutDevCommand,
  fileNames: string[],
  workspacePackageManager: string | undefined,
): string | null {
  const own = service.packageManager;
  const inherits =
    own !== null &&
    JS_PACKAGE_MANAGERS.has(own) &&
    workspacePackageManager !== undefined &&
    JS_PACKAGE_MANAGERS.has(workspacePackageManager) &&
    !fileNames.some((name) => JS_LOCKFILES.includes(name.toLowerCase()));
  return inherits ? workspacePackageManager : own;
}

async function gradleBuildScript(
  reader: ProjectReader,
  rootDirectory: string,
  fileNames: string[],
): Promise<string | null> {
  const name = GRADLE_BUILD_FILES.find((candidate) => fileNames.includes(candidate));
  return name ? ((await reader.readText(posix.join(rootDirectory, name))) ?? null) : null;
}

async function withDevCommand(
  reader: ProjectReader,
  service: ServiceWithoutDevCommand,
  workspacePackageManager?: string,
): Promise<Omit<ScannedService, "infraSource" | "envSource">> {
  if (!service.stackId) {
    return {
      service: { ...service, devCommand: null },
      warning: `Service "${service.name}" has no dev command: it has no local source to run.`,
    };
  }
  const entries = await reader.listDirectory(
    service.rootDirectory === "." ? "" : service.rootDirectory,
  );
  const fileNames = entries.map((entry) => entry.name);
  const result = deriveDevCommand({
    stackId: service.stackId as StackId,
    packageManager: devPackageManager(service, fileNames, workspacePackageManager),
    scripts: await packageScripts(reader, service.rootDirectory),
    startCommand: service.startCommand,
    port: service.port,
    workingDirectory: service.rootDirectory,
    fileNames,
    gradleBuildScript: await gradleBuildScript(reader, service.rootDirectory, fileNames),
  });
  return {
    service: { ...service, devCommand: result.devCommand },
    ...(result.problem && {
      warning: `Service "${service.name}" has no dev command: ${result.problem}.`,
    }),
  };
}

async function appService(
  reader: ProjectReader,
  id: string,
  name: string,
  source: MonorepoApp | ProjectInfo,
  workspacePackageManager?: string,
): Promise<ScannedService> {
  const rootDirectory = toRelativeDirectory(source.rootDirectory);
  const service: ServiceWithoutDevCommand = {
    id,
    name,
    kind: "app",
    rootDirectory,
    ...serviceRecipe(source),
    port: source.port,
    hasDockerfile: await fileExists(reader, posix.join(rootDirectory, DOCKERFILE)),
  };
  return {
    ...(await withDevCommand(reader, service, workspacePackageManager)),
    infraSource: { serviceId: id, directory: rootDirectory },
    envSource: { serviceId: id, serviceName: name, directory: rootDirectory, composeEnvFiles: [] },
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
): Promise<ScannedService> {
  const context = buildContext(service, composeDirectory);
  const readable = context !== null && isLocalPath(context) && isInsideRoot(context);
  const stack = readable ? await detectStackIn(reader, context) : undefined;
  const dockerfile = posix.join(context ?? ".", service.dockerfile ?? DOCKERFILE);
  const id = `compose:${service.name}`;
  const scanned = await withDevCommand(reader, {
    id,
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
  });
  return {
    ...scanned,
    envSource: {
      serviceId: id,
      serviceName: service.name,
      directory: readable ? context : composeDirectory,
      composeEnvFiles: composeEnvFiles(service, composeDirectory).readable,
    },
    infraSource: {
      serviceId: id,
      directory: readable ? context : null,
      compose: {
        name: service.name,
        image: service.image ?? null,
        environment: service.environment,
        hostPorts: portMappings(service).flatMap(({ host }) =>
          host && /^\d+$/.test(host) ? [Number(host)] : [],
        ),
      },
    },
  };
}

function composeEnvFiles(
  service: ComposeService,
  composeDirectory: string,
): { readable: EnvComposeFile[]; unreadable: string[] } {
  const readable: EnvComposeFile[] = [];
  const unreadable: string[] = [];
  for (const { path, required } of service.envFiles ?? []) {
    const relative =
      isLocalPath(path) && !posix.isAbsolute(path)
        ? toRelativeDirectory(posix.join(composeDirectory, path))
        : null;
    if (relative !== null && isInsideRoot(relative)) readable.push({ path: relative, required });
    else unreadable.push(path);
  }
  return { readable, unreadable };
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

function collectWarnings(info: ProjectInfo, composeDirectory: string): string[] {
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
    ...(info.services ?? []).flatMap((service) =>
      composeEnvFiles(service, composeDirectory).unreadable.map(
        (path) => `Service "${service.name}": env_file ${path} is not a path inside the project and was not read.`,
      ),
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
): Promise<ScannedService[]> {
  if (info.services) {
    return Promise.all(
      info.services.map((service) => composeService(reader, service, composeDirectory)),
    );
  }
  if (info.monorepoApps) {
    return Promise.all(
      info.monorepoApps.map((app) =>
        appService(
          reader,
          toRelativeDirectory(app.rootDirectory),
          app.name,
          app,
          info.monorepoWorkspace?.packageManager,
        ),
      ),
    );
  }
  return [
    await appService(reader, toRelativeDirectory(info.rootDirectory), info.repository.name, info),
  ];
}

export async function toScanResult(info: ProjectInfo, reader: ProjectReader): Promise<ScanResult> {
  const composeDirectory = toRelativeDirectory(posix.dirname(info.composeFileRead ?? "."));
  const scanned = await collectServices(info, reader, composeDirectory);
  const env = await detectEnvRequirements(
    reader,
    scanned.map(({ envSource }) => envSource),
  );
  return {
    schemaVersion: SCHEMA_VERSION,
    project: {
      name: info.repository.name,
      rootPath: info.repository.full_name,
      gitBranch: info.repository.selected_branch ?? null,
      type: info.projectType,
    },
    services: scanned.map(({ service }) => service),
    composeFiles: info.composeFiles ?? [],
    composeServices: (info.services ?? []).map((service) =>
      toComposeService(service, composeDirectory),
    ),
    envRequirements: env.envRequirements,
    infra: await detectInfra(
      reader,
      scanned.map(({ infraSource }) => infraSource),
    ),
    connections: [],
    warnings: [
      ...collectWarnings(info, composeDirectory),
      ...scanned.flatMap(({ warning }) => warning ?? []),
      ...env.warnings,
    ],
  };
}
