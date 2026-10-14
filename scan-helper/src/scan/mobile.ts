import { posix } from "node:path";
import { hasAndroidApplicationPlugin } from "./android-plugins";
import { androidSourceDirectory, MAX_ANDROID_SOURCE_FILES, MAX_ANDROID_SOURCE_BYTES } from "./android-source";
import type { ScanResult, ScanService } from "./contract";
import type { ProjectReader } from "./local-reader";

export async function detectMobileApps(reader: ProjectReader, result: ScanResult): Promise<void> {
  const tree = await reader.listTree();
  const configurations = new Map<string, string[]>();
  const androidSources = new Map<string, string[]>();
  for (const { path } of tree) {
    const module = androidSourceDirectory(path);
    if (module !== undefined) {
      const sources = androidSources.get(module) ?? [];
      sources.push(path);
      androidSources.set(module, sources);
    }
    if (posix.basename(path) !== "Info.plist" && !/^(?:AppConfiguration|APIConfiguration|Environment|Config)\.swift$/.test(posix.basename(path))) continue;
    let directory = posix.dirname(path);
    for (;;) {
      const files = configurations.get(directory) ?? [];
      files.push(path);
      configurations.set(directory, files);
      if (directory === ".") break;
      directory = posix.dirname(directory);
    }
  }
  const apps: Array<{ id: string; directory: string; platform: string; files: string[] }> = [];
  for (const entry of tree) {
    if (entry.path.endsWith(".xcodeproj/project.pbxproj")) {
      const project = await reader.readText(entry.path) ?? "";
      if (!/iphoneos|IPHONEOS_DEPLOYMENT_TARGET/.test(project)) continue;
      const directory = posix.dirname(posix.dirname(entry.path));
      const files = configurations.get(directory) ?? [];
      apps.push({ id: `mobile:ios:${posix.dirname(entry.path)}`, directory, platform: "ios", files });
    }
    if (/\bbuild\.gradle(?:\.kts)?$/.test(entry.path)) {
      const content = await reader.readText(entry.path) ?? "";
      if (!hasAndroidApplicationPlugin(content)) continue;
      const directory = posix.dirname(entry.path);
      const sources = (androidSources.get(directory) ?? []).sort().slice(0, MAX_ANDROID_SOURCE_FILES);
      apps.push({ id: `mobile:android:${directory}`, directory, platform: "android", files: [entry.path, ...sources] });
    }
  }
  for (const { id, directory, platform, files } of apps) {
    const existing = result.services.find((service) => service.id === id && service.category === "mobile" && service.stackId === platform);
    const service: ScanService = {
      id,
      name: `${directory === "." ? result.project.name : directory} (${platform === "ios" ? "iOS" : "Android"})`,
      kind: "app", rootDirectory: directory, stackId: platform, category: "mobile",
      packageManager: null, installCommand: null, buildCommand: null, startCommand: null,
      port: null, hasDockerfile: false, devCommand: null,
      runModes: {
        local: { available: false, reason: `Open this app in ${platform === "ios" ? "Xcode" : "Android Studio"} to choose a device and run it` },
        compose: { available: false, reason: "Mobile app", composeFile: null, serviceName: null },
        dockerfile: { available: false, reason: "Mobile app", dockerfilePath: null, containerPort: null },
      },
    };
    if (!existing) result.services.push(service);
    for (const file of files) {
      const content = await reader.readText(file, androidSourceDirectory(file) !== undefined ? MAX_ANDROID_SOURCE_BYTES : undefined) ?? "";
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
