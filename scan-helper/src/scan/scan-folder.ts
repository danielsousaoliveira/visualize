import { posix } from "node:path";
import type { ScanResult } from "./contract";
import { DISCOVERED_ROOT_MARKERS } from "../engine/project-root-detector";
import { createLocalReader, type ProjectReader } from "./local-reader";
import { toScanResult } from "./output";
import { mergeScan } from "./merge-scan";
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
      mergeScan(result, nested, directory, nestedInfo.composeFileRead, info.composeFileRead);
    } catch (error) {
      result.warnings.push(`${directory}: ${error instanceof Error ? error.message : "Could not scan this folder"}`);
    }
  }
  result.warnings = [...new Set(result.warnings)];
  return result;
}
