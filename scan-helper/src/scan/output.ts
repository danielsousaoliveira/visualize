import type { ComposeService } from "../engine/compose-parser";
import type { ProjectInfo } from "./resolve";

type ServiceOutput = Omit<
  ComposeService,
  "environment" | "environmentTemplates" | "environmentMeta" | "buildArgs" | "advanced"
> & {
  environmentKeys: string[];
  buildArgKeys?: string[];
};

export type ScanOutput = Omit<ProjectInfo, "rootEnv" | "services"> & {
  rootEnvKeys?: string[];
  services?: ServiceOutput[];
};

function withoutEnvValues(service: ComposeService): ServiceOutput {
  const {
    environment,
    environmentTemplates: _templates,
    environmentMeta: _meta,
    buildArgs,
    advanced: _advanced,
    ...rest
  } = service;
  return {
    ...rest,
    environmentKeys: Object.keys(environment),
    ...(buildArgs && { buildArgKeys: Object.keys(buildArgs) }),
  };
}

export function toScanOutput(info: ProjectInfo): ScanOutput {
  const { rootEnv, services, ...rest } = info;
  return {
    ...rest,
    ...(rootEnv && { rootEnvKeys: Object.keys(rootEnv) }),
    ...(services && { services: services.map(withoutEnvValues) }),
  };
}
