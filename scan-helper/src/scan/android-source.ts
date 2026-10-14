export const MAX_ANDROID_SOURCE_FILES = 128;
export const MAX_ANDROID_SOURCE_BYTES = 64 * 1024;

export function androidSourceDirectory(path: string): string | undefined {
  const match = path.match(/^(?:(.*?)\/)?src\/(?:main|debug)\/(?:(?:kotlin|java)\/.+\.(?:kt|java)|AndroidManifest\.xml)$/);
  return match ? match[1] ?? "." : undefined;
}
