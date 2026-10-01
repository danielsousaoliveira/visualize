import { vercelMetadataParser } from "./vercel";
import { railwayMetadataParser } from "./railway";
import { renderMetadataParser } from "./render";
import type { DeploymentMetadata, MetadataParser } from "./types";

export type {
  DeploymentMetadata,
  DeploymentMetadataSource,
  DeploymentRewrite,
  DeploymentRedirect,
  DeploymentHeaderRule,
  RoutingConfig,
  ProjectCompositeRoute,
  MetadataParser,
} from "./types";
export { vercelMetadataParser, parseVercelConfig, extractCdTargets, type VercelConfig } from "./vercel";
export { railwayMetadataParser } from "./railway";
export { renderMetadataParser } from "./render";

/**
 * All registered metadata parsers, in PRECEDENCE order (highest first).
 * `vercel.json` and `railway.toml`/`railway.json`
 * are authoritative build config; `render.yaml` is a fill-only fallback. Add a
 * source by implementing `MetadataParser` and appending it here.
 */
export const METADATA_PARSERS: readonly MetadataParser[] = [
  vercelMetadataParser,
  railwayMetadataParser,
  renderMetadataParser,
];

/** Lower-cased basenames of every metadata file across all parsers. */
export const METADATA_FILES: ReadonlySet<string> = new Set(
  METADATA_PARSERS.flatMap((parser) => parser.files),
);

/**
 * Run every parser over one directory's `{ lowercased-basename -> content }`
 * map and return the non-empty results in precedence order. The consumer folds
 * them over its heuristic detection (see `applyMetadataOverrides` in the stack
 * detector): authoritative sources override, `fillOnly` sources only fill gaps.
 */
export function parseDeploymentMetadata(
  fileContents: Record<string, string>,
): DeploymentMetadata[] {
  const results: DeploymentMetadata[] = [];
  for (const parser of METADATA_PARSERS) {
    const parsed = parser.parse(fileContents);
    if (parsed) results.push(parsed);
  }
  return results;
}
