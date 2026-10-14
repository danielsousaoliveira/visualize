import type { ConnectionSource } from "./connections";
import type { ScanResult } from "./contract";

export const connectionContexts = new WeakMap<ScanResult, ConnectionSource[]>();
