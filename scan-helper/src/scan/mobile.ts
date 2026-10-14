import { posix } from "node:path";
import type { ScanResult, ScanService } from "./contract";
import type { ProjectReader } from "./local-reader";

export async function detectMobileApps(reader: ProjectReader, result: ScanResult): Promise<void> {
  const tree = await reader.listTree();
  const apps: Array<{ directory: string; platform: string; files: string[] }> = [];
  for (const entry of tree) {
    if (entry.path.endsWith(".xcodeproj/project.pbxproj")) {
      const project = await reader.readText(entry.path) ?? "";
      if (!/iphoneos|IPHONEOS_DEPLOYMENT_TARGET/.test(project)) continue;
      const directory = posix.dirname(posix.dirname(entry.path));
      const files = tree.filter(({ path }) => path.startsWith(directory + "/") && (posix.basename(path) === "Info.plist" || /^(?:AppConfiguration|APIConfiguration|Environment|Config)\.swift$/.test(posix.basename(path)))).map(({ path }) => path);
      apps.push({ directory, platform: "ios", files });
    }
    if (/\bbuild\.gradle(?:\.kts)?$/.test(entry.path)) {
      const content = await reader.readText(entry.path) ?? "";
      if (!content.split("\n").some((line) => /com\.android\.application|libs\.plugins\.android\.application/.test(line) && !/apply\s*(?:\(\s*)?false/.test(line))) continue;
      apps.push({ directory: posix.dirname(entry.path), platform: "android", files: [entry.path] });
    }
  }
  for (const { directory, platform, files } of apps) {
    const existing = result.services.find((service) => service.rootDirectory === directory);
    const service: ScanService = {
      id: existing?.id ?? `mobile:${platform}:${directory}`,
      name: `${directory} (${platform === "ios" ? "iOS" : "Android"})`,
      kind: "app", rootDirectory: directory, stackId: platform, category: "mobile",
      packageManager: null, installCommand: null, buildCommand: null, startCommand: null,
      port: null, hasDockerfile: false, devCommand: null,
      runModes: {
        local: { available: false, reason: `Open this app in ${platform === "ios" ? "Xcode" : "Android Studio"} to choose a device and run it` },
        compose: { available: false, reason: "Mobile app", composeFile: null, serviceName: null },
        dockerfile: { available: false, reason: "Mobile app", dockerfilePath: null, containerPort: null },
      },
    };
    if (existing) Object.assign(existing, service);
    else result.services.push(service);
    for (const file of files) {
      const content = await reader.readText(file) ?? "";
      for (const match of content.matchAll(/https?:\/\/(?:localhost|127\.0\.0\.1|10\.0\.2\.2):([0-9]{1,5})\b/g)) {
        const port = Number(match[1]);
        const candidates = result.services.filter((candidate) => candidate.id !== service.id && candidate.category !== "mobile" &&
          (candidate.port === port || candidate.runModes.dockerfile.containerPort === port));
        if (candidates.length !== 1) continue;
        const to = candidates[0]!.id;
        if (!result.connections.some((edge) => edge.from === service.id && edge.to === to)) {
          result.connections.push({ from: service.id, to, kind: "env-url", label: "Local API" });
        }
      }
    }
  }
}
