export const SCHEMA_VERSION = 1;

export type ScanProjectType = "app" | "monorepo" | "services" | "docker";

export type ScanServiceKind = "app" | "compose";

export interface ScanProject {
  name: string;
  rootPath: string;
  gitBranch: string | null;
  type: ScanProjectType;
}

export interface ScanService {
  id: string;
  name: string;
  kind: ScanServiceKind;
  rootDirectory: string;
  stackId: string | null;
  category: string | null;
  packageManager: string | null;
  installCommand: string | null;
  buildCommand: string | null;
  startCommand: string | null;
  port: number | null;
  hasDockerfile: boolean;
}

export interface ScanPortMapping {
  host: string | null;
  container: string;
}

export interface ScanComposeService {
  name: string;
  image: string | null;
  buildContext: string | null;
  ports: ScanPortMapping[];
  dependsOn: string[];
  environment: string[];
}

export interface ScanResult {
  schemaVersion: typeof SCHEMA_VERSION;
  project: ScanProject;
  services: ScanService[];
  composeFiles: string[];
  composeServices: ScanComposeService[];
  envRequirements: never[];
  infra: never[];
  connections: never[];
  warnings: string[];
}
