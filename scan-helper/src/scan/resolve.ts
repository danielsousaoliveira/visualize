import { stat, realpath } from "node:fs/promises";
import { basename } from "node:path";
import { readGitBranch } from "./git-branch";
import { MANIFEST_FILES, type RepoFile, type StackResult } from "../engine/stack-detector";
import {
  blockingComposeFields,
  describeBlockingComposeFields,
  parseComposeEnvFile,
  parseComposeFile,
  type ComposeMissingVariable,
  type ComposeService,
  type ComposeUnsupportedField,
} from "../engine/compose-parser";
import {
  applyWorkspaceContext,
  discoverMonorepoApps,
  discoverProjectRootHints,
  normalizeProjectRootDirectory,
  selectPreferredProjectRoot,
  type MonorepoApp,
  type MonorepoWorkspace,
  type ProjectRootSnapshot,
  type ProjectRootSnapshotInput,
  type RepoTreeEntry,
} from "../engine/project-root-detector";
import {
  parseDeploymentMetadata,
  METADATA_FILES,
  type ProjectType,
  type RoutingConfig,
} from "../core";
import { createLocalReader, type ProjectReader } from "./local-reader";

const PREPARE_FILE_CONTENTS = [
  ...MANIFEST_FILES,
  // Platform-config files (vercel.json / render.yaml / railway.{toml,json}) come
  // from the metadata parser registry, so adding a parser reads its file here too.
  ...METADATA_FILES,
  "pnpm-workspace.yaml",
  "turbo.json",
  "nx.json",
  "rush.json",
] as const;
const COMPOSE_FILES = [
  "docker-compose.yml",
  "docker-compose.yaml",
  "compose.yml",
  "compose.yaml",
] as const;

export class ComposeConfigurationError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "ComposeConfigurationError";
  }
}

export interface ProjectInfo {
  repository: {
    name: string;
    full_name: string;
    owner: { login: string };
    private: boolean;
    default_branch: string;
    selected_branch?: string;
  };
  stack: StackResult["stack"];
  projectType: ProjectType;
  category: string;
  packageManager: string;
  buildCommand: string;
  installCommand: string;
  startCommand: string;
  buildImage: string;
  outputDirectory: string;
  rootDirectory: string;
  productionPaths: string[];
  port: number;
  services?: ComposeService[];
  composeFiles?: string[];
  composeFileRead?: string;
  /** Compose variables the file marks mandatory that no `.env` value
   *  satisfied. Absent when there are none. */
  missingRequiredEnv?: ComposeMissingVariable[];
  /** Compose keys the file declares that the parser doesn't model. Blocking ones
   *  never reach here: they refuse the scan instead. Absent when there are none. */
  unsupportedCompose?: ComposeUnsupportedField[];
  monorepoApps?: MonorepoApp[];
  monorepoWorkspace?: MonorepoWorkspace;
  rootEnv?: Record<string, string>;
  /** Routing config parsed from the repo-root `vercel.json`
   *  (rewrites/redirects/headers/cleanUrls/trailingSlash). */
  routing?: RoutingConfig;
}

/**
 * Routing config is a repo-ROOT concern (the root `vercel.json`), so read it
 * from the root snapshot's file contents regardless of which sub-app is selected
 * as the primary. Returns the first source that declares routing (vercel today).
 */
function extractRootRouting(fileContents: Record<string, string>): RoutingConfig | undefined {
  const lower: Record<string, string> = {};
  for (const [name, content] of Object.entries(fileContents)) lower[name.toLowerCase()] = content;
  for (const meta of parseDeploymentMetadata(lower)) {
    if (meta.routing) return meta.routing;
  }
  return undefined;
}

function joinProjectPath(rootDirectory: string, name: string): string {
  const normalizedRootDirectory = normalizeProjectRootDirectory(rootDirectory);
  return normalizedRootDirectory ? `${normalizedRootDirectory}/${name}` : name;
}

const NESTED_MARKERS: Record<string, string[]> = {
  bin: ["rails"],
  config: ["routes.rb", "config.exs"],
};

async function listNestedMarkers(
  reader: ProjectReader,
  rootDirectory: string,
  topLevel: RepoFile[],
): Promise<RepoFile[]> {
  const found = await Promise.all(
    Object.entries(NESTED_MARKERS)
      .filter(([dir]) => topLevel.some((file) => file.type === "dir" && file.name === dir))
      .map(async ([dir, names]) => {
        const entries = await reader.listDirectory(joinProjectPath(rootDirectory, dir));
        return entries
          .filter((entry) => entry.type !== "dir" && names.includes(entry.name.toLowerCase()))
          .map((entry) => ({ name: `${dir}/${entry.name}`, type: "file" }));
      }),
  );
  return found.flat();
}

export async function readProjectSnapshot(
  reader: ProjectReader,
  rootDirectory = "",
  source: ProjectRootSnapshotInput["source"] = "root",
): Promise<ProjectRootSnapshotInput> {
  const normalizedRootDirectory = normalizeProjectRootDirectory(rootDirectory);
  const topLevel = await reader.listDirectory(normalizedRootDirectory);
  const files = [...topLevel, ...(await listNestedMarkers(reader, normalizedRootDirectory, topLevel))];
  const packageJson = await reader.readJson(
    joinProjectPath(normalizedRootDirectory, "package.json"),
  );
  const fileContents: Record<string, string> = {};

  await Promise.all(
    PREPARE_FILE_CONTENTS.filter((name) =>
      files.some((file) => file.name.toLowerCase() === name.toLowerCase()),
    ).map(async (name) => {
      const content = await reader.readText(joinProjectPath(normalizedRootDirectory, name));
      if (content) {
        fileContents[name] = content;
      }
    }),
  );

  // Workspace/project manifests with dynamic basenames - PREPARE_FILE_CONTENTS
  // is a static list, but .NET solution/project files are named per-repo (e.g.
  // `MedicaScopeLMS.sln`, `Api.csproj`) so the lowercase-equality match above
  // would miss them. Without the .sln body, `detectWorkspaces` can't discover
  // sub-projects; without each .csproj/.fsproj body, we can't tell a deployable
  // web/service project from a class library (see isDotnetLibraryOnly), so every
  // project in a solution wrongly becomes its own deployable app.
  await Promise.all(
    files
      .filter((file) => /\.(sln|csproj|fsproj)$/i.test(file.name))
      .map(async (file) => {
        const content = await reader.readText(joinProjectPath(normalizedRootDirectory, file.name));
        if (content) {
          fileContents[file.name] = content;
        }
      }),
  );

  return {
    rootDirectory: normalizedRootDirectory,
    files,
    packageJson,
    fileContents,
    source,
  };
}

async function loadCandidateSnapshot(
  reader: ProjectReader,
  rootDirectory: string,
  source: ProjectRootSnapshotInput["source"],
): Promise<ProjectRootSnapshotInput | null> {
  const snapshot = await readProjectSnapshot(reader, rootDirectory, source);
  if (!snapshot.rootDirectory || snapshot.files.length === 0) {
    return null;
  }

  return snapshot;
}

interface SelectedProjectSnapshot {
  selected: ProjectRootSnapshot;
  monorepo: { apps: MonorepoApp[]; workspace: MonorepoWorkspace } | null;
}

async function selectProjectSnapshot(
  reader: ProjectReader,
  rootSnapshot: ProjectRootSnapshotInput,
): Promise<SelectedProjectSnapshot> {
  const treeEntries = await reader.listTree().catch(() => [] as RepoTreeEntry[]);
  const hints = discoverProjectRootHints(
    treeEntries,
    rootSnapshot.fileContents,
    rootSnapshot.packageJson,
  );

  const candidates = (
    await Promise.all(
      hints.map((hint) => loadCandidateSnapshot(reader, hint.rootDirectory, hint.source)),
    )
  ).filter((candidate): candidate is ProjectRootSnapshotInput => Boolean(candidate));

  const selected = applyWorkspaceContext(
    rootSnapshot,
    selectPreferredProjectRoot(rootSnapshot, candidates),
  );
  const monorepo = discoverMonorepoApps(rootSnapshot, candidates);

  return { selected, monorepo };
}

async function readProjectText(
  reader: ProjectReader,
  rootDirectory: string,
  name: string,
): Promise<string | undefined> {
  return reader.readText(joinProjectPath(rootDirectory, name));
}

/** Which of `candidates` this directory listing actually holds, in candidate order. */
function presentComposeFiles(files: RepoFile[], candidates: readonly string[]): string[] {
  return candidates.filter((candidate) =>
    files.some((file) => file.name.toLowerCase() === candidate.toLowerCase()),
  );
}

/** Read the first of `names` that yields content. Names are already known present. */
async function readComposeText(
  reader: ProjectReader,
  rootDirectory: string,
  names: string[],
): Promise<{ name: string; content: string } | undefined> {
  for (const name of names) {
    const content = await readProjectText(reader, rootDirectory, name);
    if (content) {
      return { name, content };
    }
  }

  return undefined;
}

type RepoMeta = ProjectInfo["repository"];

/**
 * Shared resolution pipeline: snapshot → resolve root → read compose/.env → map.
 */
export async function resolveFromReader(
  reader: ProjectReader,
  repository: RepoMeta,
): Promise<ProjectInfo> {
  const rootSnapshot = await readProjectSnapshot(reader);
  const routing = extractRootRouting(rootSnapshot.fileContents ?? {});
  const { selected, monorepo } = await selectProjectSnapshot(reader, rootSnapshot);
  const composeFiles = presentComposeFiles(selected.files, COMPOSE_FILES);

  // `.env` sits next to the compose file, which is what compose itself resolves against.
  const [compose, composeEnvContent] = await Promise.all([
    readComposeText(reader, selected.rootDirectory, composeFiles),
    readProjectText(reader, selected.rootDirectory, ".env"),
  ]);

  const info = toProjectInfo(
    repository,
    selected,
    compose?.content,
    composeEnvContent,
    monorepo,
    routing,
  );
  if (composeFiles.length === 0) return info;
  const toRootPath = (name: string) => joinProjectPath(selected.rootDirectory, name);
  return {
    ...info,
    composeFiles: composeFiles.map(toRootPath),
    ...(compose && { composeFileRead: toRootPath(compose.name) }),
  };
}

export async function resolveFromLocal(dirPath: string): Promise<ProjectInfo> {
  const st = await stat(dirPath);
  if (!st.isDirectory()) {
    throw new Error("Path is not a directory");
  }

  const root = await realpath(dirPath);
  const reader = createLocalReader(root);
  const rootPackageJson = await reader.readJson("package.json");
  const name = typeof rootPackageJson?.name === "string" ? rootPackageJson.name : basename(root);
  const branch = await readGitBranch(root);

  return resolveFromReader(reader, {
    name,
    full_name: root,
    owner: { login: "local" },
    private: true,
    default_branch: "main",
    ...(branch && { selected_branch: branch }),
  });
}

const PORT_SPEC =
  /^(?:(?:\d{1,3}(?:\.\d{1,3}){3}|\[[0-9A-Fa-f:]+\]):)?(?:\d{1,5}(?:-\d{1,5})?:)?\d{1,5}(?:-\d{1,5})?(?:\/(?:tcp|udp|sctp))?$/;

function isPortSpec(value: string): boolean {
  return PORT_SPEC.test(value);
}

function expressionsFor(names: string[]): Record<string, string> {
  return Object.fromEntries(names.map((name) => [name, `\${${name}}`]));
}

function withResolvedPorts(
  services: ComposeService[],
  resolved: ComposeService[],
): ComposeService[] {
  const resolvedPorts = new Map(resolved.map((service) => [service.name, service.ports]));
  return services.map((service) => {
    const ports = resolvedPorts.get(service.name);
    return ports && ports.every(isPortSpec) ? { ...service, ports } : service;
  });
}

function toProjectInfo(
  repository: RepoMeta,
  projectRoot: ProjectRootSnapshot,
  composeContent?: string,
  composeEnvContent?: string,
  monorepo?: { apps: MonorepoApp[]; workspace: MonorepoWorkspace } | null,
  routing?: RoutingConfig,
): ProjectInfo {
  const stack = projectRoot.stack;
  const rootEnv = composeEnvContent ? parseComposeEnvFile(composeEnvContent) : {};

  let services: ComposeService[] | undefined;
  let missingRequiredEnv: ComposeMissingVariable[] | undefined;
  let unsupportedCompose: ComposeUnsupportedField[] | undefined;
  if (composeContent) {
    try {
      const parsed = parseComposeFile(composeContent, {
        env: expressionsFor(Object.keys(rootEnv)),
      });
      const resolved = parseComposeFile(composeContent, { envFileContent: composeEnvContent });
      services = withResolvedPorts(parsed.services, resolved.services);
      // Values the file demands (`${VAR:?…}`) that nothing here supplied. NOT an
      // error: the list to prompt for, not a reason to refuse the repo.
      if (resolved.missingRequired.length > 0) missingRequiredEnv = resolved.missingRequired;
      // Keys we can't honor, so the caller can show what won't carry over.
      if (parsed.unsupported.length > 0) unsupportedCompose = parsed.unsupported;
    } catch (err) {
      // Surface the broken file — swallowing it would return a services project
      // with ZERO services and no reason why.
      const detail = err instanceof Error && err.message ? err.message : "Unknown parser error";
      throw new ComposeConfigurationError(`Could not parse the Docker Compose file: ${detail}`, {
        cause: err,
      });
    }

    // A BLOCKING key refuses the scan, outside the parse try/catch so it never
    // reads as "could not parse" — the file is valid, it just asks for something
    // that cannot be run faithfully.
    const blocking = blockingComposeFields(unsupportedCompose ?? []);
    if (blocking.length > 0) {
      throw new ComposeConfigurationError(
        `The Docker Compose file declares options that can't be run faithfully:\n` +
          describeBlockingComposeFields(blocking),
      );
    }
  }

  // Monorepo wins over the single-root projectType: when the root has a workspace
  // manifest AND we found 2+ deployable apps, expose the multi-app flow.
  const isMonorepo = stack.projectType !== "services" && monorepo && monorepo.apps.length >= 2;
  const projectType: ProjectType = isMonorepo ? "monorepo" : stack.projectType;

  return {
    repository,
    stack: stack.stack,
    projectType,
    category: stack.category,
    packageManager: stack.packageManager,
    buildCommand: stack.buildCommand,
    installCommand: stack.installCommand,
    startCommand: stack.startCommand,
    buildImage: stack.buildImage,
    outputDirectory: stack.outputDirectory,
    rootDirectory: projectRoot.rootDirectory || "./",
    productionPaths: stack.productionPaths,
    port: stack.port,
    ...(services && { services }),
    ...(missingRequiredEnv && { missingRequiredEnv }),
    ...(unsupportedCompose && { unsupportedCompose }),
    ...(isMonorepo && monorepo
      ? { monorepoApps: monorepo.apps, monorepoWorkspace: monorepo.workspace }
      : {}),
    ...(Object.keys(rootEnv).length > 0 && { rootEnv }),
    ...(routing && { routing }),
  };
}
