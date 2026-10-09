import { posix } from "node:path";
import type { ScanResult } from "./contract";
import { DISCOVERED_ROOT_MARKERS } from "../engine/project-root-detector";
import { createLocalReader, type ProjectReader } from "./local-reader";
import { toScanResult } from "./output";
import { resolveFromLocal, resolveFromReader } from "./resolve";

function scopedReader(reader: ProjectReader, directory: string): ProjectReader {
  const path = (value: string) => posix.join(directory, value);
  return {
    listDirectory: (value) => reader.listDirectory(path(value)),
    readText: (value) => reader.readText(path(value)),
    readJson: (value) => reader.readJson(path(value)),
    listTree: async () => [],
  };
}

function mergeScan(result: ScanResult, nested: ScanResult, directory: string, composeFileRead?: string): void {
  const path = (value: string) => posix.join(directory, value);
  const ids = new Map<string, string>();
  const id = (value: string) => {
    const mapped = ids.get(value);
    if (mapped) return mapped;
    if (directory === ".") return value;
    if (value.startsWith("infra:")) return `infra:${directory}::${value.slice(6)}`;
    if (value.startsWith("compose:")) return `compose:${directory}::${value.slice(8)}`;
    return path(value);
  };
  const added = new Set<string>();
  for (const service of nested.services) {
    const rootDirectory = path(service.rootDirectory);
    if (!service.devCommand && !service.runModes.compose.available && !service.runModes.dockerfile.available) continue;
    const composeFile = service.runModes.compose.composeFile ? path(service.runModes.compose.composeFile) : null;
    const existing = result.services.find((candidate) =>
      composeFile !== null
        ? candidate.runModes.compose.composeFile === composeFile && candidate.runModes.compose.serviceName === service.runModes.compose.serviceName
        : candidate.rootDirectory === rootDirectory && candidate.devCommand !== null,
    );
    if (existing) { ids.set(service.id, existing.id); continue; }
    const serviceID = service.kind === "app" ? rootDirectory : id(service.id);
    ids.set(service.id, serviceID);
    added.add(serviceID);
    result.services.push({
      ...service,
      id: serviceID,
      name: directory === "." ? service.name : `${directory}/${service.name}`,
      rootDirectory,
      devCommand: service.devCommand ? { ...service.devCommand, workingDirectory: path(service.devCommand.workingDirectory) } : null,
      runModes: {
        ...service.runModes,
        compose: { ...service.runModes.compose, composeFile },
        dockerfile: {
          ...service.runModes.dockerfile,
          dockerfilePath: service.runModes.dockerfile.dockerfilePath ? path(service.runModes.dockerfile.dockerfilePath) : null,
        },
      },
    });
  }
  const newFiles = nested.composeFiles.map(path).filter((file) => !result.composeFiles.includes(file));
  if (!added.size && !newFiles.length) return;
  for (const infra of nested.infra) {
    const providedBy = infra.providedBy ? id(infra.providedBy) : null;
    const usedBy = infra.usedBy.map(id).filter((value) => result.services.some((service) => service.id === value));
    if (!usedBy.length && !providedBy) continue;
    const existing = result.infra.find((candidate) =>
      candidate.kind === infra.kind && (providedBy !== null ? candidate.providedBy === providedBy : candidate.providedBy === null && candidate.host === infra.host && candidate.port === infra.port),
    );
    if (existing) {
      ids.set(infra.id, existing.id);
      existing.usedBy = [...new Set([...existing.usedBy, ...usedBy])];
      continue;
    }
    const infraID = id(infra.id);
    ids.set(infra.id, infraID);
    result.infra.push({ ...infra, id: infraID, providedBy, usedBy });
  }
  const endpoints = new Set([...result.services.map((service) => service.id), ...result.infra.map((infra) => infra.id)]);
  for (const connection of nested.connections) {
    const mapped = { ...connection, from: id(connection.from), to: id(connection.to) };
    if (endpoints.has(mapped.from) && endpoints.has(mapped.to) && !result.connections.some((candidate) => JSON.stringify(candidate) === JSON.stringify(mapped))) result.connections.push(mapped);
  }
  result.envRequirements.push(...nested.envRequirements.filter((entry) => added.has(id(entry.serviceId))).map((entry) => ({
    ...entry,
    serviceId: id(entry.serviceId),
    variables: entry.variables.map((variable) => ({ ...variable, declaredIn: variable.declaredIn.map(path) })),
  })));
  result.composeFiles.push(...newFiles);
  if (newFiles.length) {
    result.composeServices.push(...nested.composeServices.map((service) => ({
      ...service,
      composeFile: service.composeFile ? path(service.composeFile) : composeFileRead ? path(composeFileRead) : newFiles[0],
      buildContext: service.buildContext && !service.buildContext.includes("://") && !posix.isAbsolute(service.buildContext) ? path(service.buildContext) : service.buildContext,
    })));
  }
  if (added.size || newFiles.length) result.warnings.push(...nested.warnings.map((warning) => `${directory}: ${warning}`));
}

export async function scanFolder(path: string): Promise<ScanResult> {
  const info = await resolveFromLocal(path);
  const reader = createLocalReader(info.repository.full_name);
  const result = await toScanResult(info, reader);
  const directories = [...new Set((await reader.listTree())
    .filter((entry) => DISCOVERED_ROOT_MARKERS.has(posix.basename(entry.path).toLowerCase()) || /\.(cs|fs)proj$/i.test(entry.path))
    .map((entry) => posix.dirname(entry.path)))].sort();
  for (const directory of directories) {
    if (directory === "." && info.rootDirectory === "./") continue;
    const hasNewCompose = (await reader.listDirectory(directory === "." ? "" : directory)).some((file) =>
      /^(?:docker-compose|compose)\.ya?ml$/i.test(file.name) && !result.composeFiles.includes(posix.join(directory, file.name)),
    );
    if (!hasNewCompose && result.services.some((service) => service.rootDirectory === directory)) continue;
    const scoped = scopedReader(reader, directory);
    try {
      const nestedInfo = await resolveFromReader(scoped, {
        ...info.repository,
        name: posix.basename(directory === "." ? info.repository.full_name : directory),
      });
      const nested = await toScanResult(nestedInfo, scoped);
      for (const service of nested.services) {
        if (service.kind === "compose" || service.devCommand?.source !== "fallback-start") continue;
        const manifest = await scoped.readJson(posix.join(service.rootDirectory, "package.json"));
        if (manifest) {
          service.devCommand = null;
          service.runModes.local = { available: false, reason: "No runnable development script detected" };
        }
      }
      if (new Set([...result.composeFiles, ...nested.composeFiles.map((file) => posix.join(directory, file))]).size > result.composeFiles.length) {
        result.composeServices = result.composeServices.map((service) => ({ ...service, composeFile: service.composeFile ?? info.composeFileRead }));
      }
      mergeScan(result, nested, directory, nestedInfo.composeFileRead);
    } catch (error) {
      result.warnings.push(`${directory}: ${error instanceof Error ? error.message : "Could not scan this folder"}`);
    }
  }
  result.warnings = [...new Set(result.warnings)];
  return result;
}
