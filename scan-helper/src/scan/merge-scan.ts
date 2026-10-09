import { posix } from "node:path";
import type { ScanResult } from "./contract";
import { NestedScanMapping } from "./nested-scan-mapping";

function mergeServices(result: ScanResult, nested: ScanResult, mapping: NestedScanMapping): Set<string> {
  const added = new Set<string>();
  for (const service of nested.services) {
    const rootDirectory = mapping.path(service.rootDirectory);
    if (!service.devCommand && !service.runModes.compose.available && !service.runModes.dockerfile.available) continue;
    const composeFile = service.runModes.compose.composeFile ? mapping.path(service.runModes.compose.composeFile) : null;
    const existing = result.services.find((candidate) =>
      composeFile !== null
        ? candidate.runModes.compose.composeFile === composeFile && candidate.runModes.compose.serviceName === service.runModes.compose.serviceName
        : candidate.rootDirectory === rootDirectory && candidate.devCommand !== null,
    );
    if (existing) { mapping.record(service.id, existing.id); continue; }
    const serviceID = service.kind === "app" ? rootDirectory : mapping.resolve(service.id);
    mapping.record(service.id, serviceID);
    added.add(serviceID);
    result.services.push({
      ...service,
      id: serviceID,
      name: mapping.directory === "." ? service.name : `${mapping.directory}/${service.name}`,
      rootDirectory,
      devCommand: service.devCommand ? { ...service.devCommand, workingDirectory: mapping.path(service.devCommand.workingDirectory) } : null,
      runModes: {
        ...service.runModes,
        compose: { ...service.runModes.compose, composeFile },
        dockerfile: {
          ...service.runModes.dockerfile,
          dockerfilePath: service.runModes.dockerfile.dockerfilePath ? mapping.path(service.runModes.dockerfile.dockerfilePath) : null,
        },
      },
    });
  }
  return added;
}

function mergeInfrastructure(result: ScanResult, nested: ScanResult, mapping: NestedScanMapping): void {
  for (const infra of nested.infra) {
    const providedBy = infra.providedBy ? mapping.resolve(infra.providedBy) : null;
    const usedBy = infra.usedBy.map((value) => mapping.resolve(value)).filter((value) => result.services.some((service) => service.id === value));
    if (!usedBy.length && !providedBy) continue;
    const existing = result.infra.find((candidate) =>
      candidate.kind === infra.kind && (providedBy !== null ? candidate.providedBy === providedBy : candidate.providedBy === null && candidate.host === infra.host && candidate.port === infra.port),
    );
    if (existing) {
      mapping.record(infra.id, existing.id);
      existing.usedBy = [...new Set([...existing.usedBy, ...usedBy])];
      continue;
    }
    const infraID = mapping.resolve(infra.id);
    mapping.record(infra.id, infraID);
    result.infra.push({ ...infra, id: infraID, providedBy, usedBy });
  }
}

function mergeConnections(result: ScanResult, nested: ScanResult, mapping: NestedScanMapping): void {
  const endpoints = new Set([...result.services.map((service) => service.id), ...result.infra.map((infra) => infra.id)]);
  for (const connection of nested.connections) {
    const mapped = { ...connection, from: mapping.resolve(connection.from), to: mapping.resolve(connection.to) };
    if (endpoints.has(mapped.from) && endpoints.has(mapped.to) && !result.connections.some((candidate) => JSON.stringify(candidate) === JSON.stringify(mapped))) result.connections.push(mapped);
  }
}

function mergeEnvironment(result: ScanResult, nested: ScanResult, mapping: NestedScanMapping, added: Set<string>): void {
  result.envRequirements.push(...nested.envRequirements.filter((entry) => added.has(mapping.resolve(entry.serviceId))).map((entry) => ({
    ...entry,
    serviceId: mapping.resolve(entry.serviceId),
    variables: entry.variables.map((variable) => ({ ...variable, declaredIn: variable.declaredIn.map((value) => mapping.path(value)) })),
  })));
}

function mergeCompose(result: ScanResult, nested: ScanResult, mapping: NestedScanMapping, newFiles: string[], composeFileRead?: string, rootComposeFileRead?: string): void {
  if (newFiles.length) {
    result.composeServices = result.composeServices.map((service) => ({ ...service, composeFile: service.composeFile ?? rootComposeFileRead }));
  }
  result.composeFiles.push(...newFiles);
  if (newFiles.length) {
    result.composeServices.push(...nested.composeServices.map((service) => ({
      ...service,
      composeFile: service.composeFile ? mapping.path(service.composeFile) : composeFileRead ? mapping.path(composeFileRead) : newFiles[0],
      buildContext: service.buildContext && !service.buildContext.includes("://") && !posix.isAbsolute(service.buildContext) ? mapping.path(service.buildContext) : service.buildContext,
    })));
  }
}

export function mergeScan(result: ScanResult, nested: ScanResult, directory: string, composeFileRead?: string, rootComposeFileRead?: string): void {
  const mapping = new NestedScanMapping(directory);
  const added = mergeServices(result, nested, mapping);
  const newFiles = nested.composeFiles.map((value) => mapping.path(value)).filter((file) => !result.composeFiles.includes(file));
  if (!added.size && !newFiles.length) return;
  mergeInfrastructure(result, nested, mapping);
  mergeConnections(result, nested, mapping);
  mergeEnvironment(result, nested, mapping, added);
  mergeCompose(result, nested, mapping, newFiles, composeFileRead, rootComposeFileRead);
  result.warnings.push(...nested.warnings.map((warning) => `${directory}: ${warning}`));
}
