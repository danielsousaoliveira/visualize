import { posix } from "node:path";

export class NestedScanMapping {
  private readonly identities = new Map<string, string>();

  constructor(readonly directory: string) {}

  path(value: string): string {
    return posix.join(this.directory, value);
  }

  record(nestedID: string, mergedID: string): void {
    this.identities.set(nestedID, mergedID);
  }

  resolve(nestedID: string): string {
    return this.identities.get(nestedID) ?? this.scopedID(nestedID);
  }

  private scopedID(value: string): string {
    if (this.directory === ".") return value;
    if (value.startsWith("infra:")) return `infra:${this.directory}::${value.slice(6)}`;
    if (value.startsWith("compose:")) return `compose:${this.directory}::${value.slice(8)}`;
    return this.path(value);
  }
}
