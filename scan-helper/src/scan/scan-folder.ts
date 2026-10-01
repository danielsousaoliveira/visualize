import type { ScanResult } from "./contract";
import { createLocalReader } from "./local-reader";
import { toScanResult } from "./output";
import { resolveFromLocal } from "./resolve";

export async function scanFolder(path: string): Promise<ScanResult> {
  const info = await resolveFromLocal(path);
  return toScanResult(info, createLocalReader(info.repository.full_name));
}
