import { posix } from "node:path";
import type { ScanRunModes, ScanService } from "./contract";
import type { ProjectReader } from "./local-reader";
import type { ProjectInfo } from "./resolve";

export function exposedPort(content: string): number | null {
  let port: number | null = null;
  const lines = content.replace(/\\\r?\n/g, " ").split(/\r?\n/);
  for (const line of lines) {
    if (/^\s*FROM\s/i.test(line)) port = null;
    const expose = line.match(/^\s*EXPOSE\s+(.+)/i);
    if (!expose || port !== null) continue;
    for (const token of expose[1]!.split(/\s+/)) {
      if (token.startsWith("#")) break;
      const match = token.match(/^(\d{1,5})(?:\/(?:tcp|udp))?$/i);
      const value = match ? Number(match[1]) : 0;
      if (value > 0 && value <= 65535) {
        port = value;
        break;
      }
    }
  }
  return port;
}

export async function detectRunModes(
  reader: ProjectReader,
  service: Omit<ScanService, "runModes">,
  info: ProjectInfo,
): Promise<ScanRunModes> {
  const composeDirectory = posix.dirname(info.composeFileRead ?? ".");
  const compose = info.services?.find((candidate) =>
    service.kind === "compose"
      ? service.id === `compose:${candidate.name}`
      : candidate.build !== undefined &&
        posix.normalize(posix.join(composeDirectory, candidate.build)) === service.rootDirectory,
  );
  const dockerfilePath = posix.join(service.rootDirectory, compose?.dockerfile ?? "Dockerfile");
  const context = compose?.build;
  const localContext = context !== undefined &&
    !posix.isAbsolute(context) && !context.includes("://") &&
    !context.includes("$") && !context.startsWith("git@") &&
    posix.normalize(posix.join(composeDirectory, context)) === service.rootDirectory;
  const canReadDockerfile = service.kind !== "compose" || localContext;
  const content = canReadDockerfile ? await reader.readText(dockerfilePath) : undefined;
  return {
    local: {
      available: service.devCommand !== null,
      reason: service.devCommand ? null : "no dev command detected",
    },
    compose: {
      available: compose !== undefined && info.composeFileRead !== undefined,
      reason: compose && info.composeFileRead ? null : "no compose service for service root",
      composeFile: compose ? info.composeFileRead ?? null : null,
      serviceName: compose ? compose.name : null,
    },
    dockerfile: {
      available: content !== undefined,
      reason: content !== undefined ? null : "no Dockerfile in service root",
      dockerfilePath: content !== undefined ? dockerfilePath : null,
      containerPort: content !== undefined ? exposedPort(content) ?? service.port : null,
    },
  };
}
