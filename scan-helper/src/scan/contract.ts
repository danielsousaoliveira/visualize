export const SCHEMA_VERSION = 1;

export type ScanProjectType = "app" | "monorepo" | "services" | "docker";

export type ScanServiceKind = "app" | "compose";

export interface ScanProject {
  name: string;
  rootPath: string;
  gitBranch: string | null;
  type: ScanProjectType;
}

export interface ScanDevCommand {
  argv: string[];
  workingDirectory: string;
  source: string;
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
  devCommand: ScanDevCommand | null;
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

export type ScanInfraKind = "postgres" | "mysql" | "mongodb" | "redis" | "sqlite";

export interface ScanInfra {
  kind: ScanInfraKind;
  usedBy: string[];
  providedBy: string | null;
  evidence: string[];
  host: string | null;
  port: number | null;
}

export type ScanEnvStatus = "set" | "missing" | "extra";

export interface ScanEnvVariable {
  name: string;
  status: ScanEnvStatus;
  declaredIn: string[];
}

export interface ScanEnvRequirement {
  serviceId: string;
  variables: ScanEnvVariable[];
}

export interface ScanResult {
  schemaVersion: typeof SCHEMA_VERSION;
  project: ScanProject;
  services: ScanService[];
  composeFiles: string[];
  composeServices: ScanComposeService[];
  envRequirements: ScanEnvRequirement[];
  infra: ScanInfra[];
  connections: never[];
  warnings: string[];
}
