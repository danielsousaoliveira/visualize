import { posix } from "node:path";
import { envFileKeys, type EnvFileKeys } from "../core/env-file";
import type { ScanEnvRequirement, ScanEnvStatus, ScanEnvVariable } from "./contract";
import type { ProjectReader } from "./local-reader";

export const EXAMPLE_ENV_FILES = [".env.example", ".env.sample", ".env.template"];
export const REAL_ENV_FILES = [".env", ".env.local", ".env.development", ".env.development.local"];

export interface EnvComposeFile {
  path: string;
  required: boolean;
}

export interface EnvSource {
  serviceId: string;
  serviceName: string;
  directory: string;
  composeEnvFiles: EnvComposeFile[];
}

export interface EnvRequirementsResult {
  envRequirements: ScanEnvRequirement[];
  warnings: string[];
}

interface EnvFileRead {
  path: string;
  example: boolean;
  parsed: EnvFileKeys | undefined;
}

interface Tally {
  expected: boolean;
  set: boolean;
  declaredIn: string[];
}

function unique<T>(values: T[]): T[] {
  return [...new Set(values)];
}

function status({ expected, set }: Tally): ScanEnvStatus | undefined {
  if (expected) return set ? "set" : "missing";
  return set ? "extra" : undefined;
}

function toVariables(files: EnvFileRead[]): ScanEnvVariable[] {
  const tallies = new Map<string, Tally>();
  for (const { path, example, parsed } of files) {
    for (const { key, hasValue } of parsed?.keys ?? []) {
      const tally = tallies.get(key) ?? { expected: false, set: false, declaredIn: [] };
      tallies.set(key, tally);
      if (example) tally.expected = true;
      else if (hasValue) tally.set = true;
      if (!tally.declaredIn.includes(path)) tally.declaredIn.push(path);
    }
  }
  return [...tallies]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .flatMap(([name, tally]) => {
      const found = status(tally);
      return found ? [{ name, status: found, declaredIn: tally.declaredIn }] : [];
    });
}

export async function detectEnvRequirements(
  reader: ProjectReader,
  sources: EnvSource[],
): Promise<EnvRequirementsResult> {
  const cache = new Map<string, Promise<EnvFileKeys | undefined>>();
  const read = (path: string, example: boolean): Promise<EnvFileRead> => {
    if (!cache.has(path)) {
      cache.set(
        path,
        reader.readText(path).then((content) => (content === undefined ? undefined : envFileKeys(content))),
      );
    }
    return cache.get(path)!.then((parsed) => ({ path, example, parsed }));
  };

  const scanned = await Promise.all(
    sources.map(async ({ serviceId, serviceName, directory, composeEnvFiles }) => {
      const directories = unique([".", directory]);
      const inDirectories = (names: string[]) =>
        unique(directories.flatMap((dir) => names.map((name) => posix.join(dir, name))));
      const realPaths = inDirectories(REAL_ENV_FILES);
      const composeFiles = composeEnvFiles.filter(({ path }) => !realPaths.includes(path));
      const files = await Promise.all([
        ...inDirectories(EXAMPLE_ENV_FILES).map((path) => read(path, true)),
        ...[...realPaths, ...composeFiles.map(({ path }) => path)].map((path) => read(path, false)),
      ]);
      const notFound = composeFiles
        .filter(({ path, required }) => required && !files.find((file) => file.path === path)?.parsed)
        .map(({ path }) => `Service "${serviceName}": env_file ${path} was not found.`);
      return { requirement: { serviceId, variables: toVariables(files) }, warnings: notFound };
    }),
  );

  const malformed: string[] = [];
  for (const [path, pending] of cache) {
    for (const line of (await pending)?.malformedLines ?? []) {
      malformed.push(`Env file ${path}, line ${line}, could not be parsed and was skipped.`);
    }
  }
  return {
    envRequirements: scanned.map(({ requirement }) => requirement),
    warnings: [...malformed, ...scanned.flatMap(({ warnings }) => warnings)],
  };
}
