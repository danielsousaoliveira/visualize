/** Normalize repository-relative roots for discovery and config override matching. */
export function normalizeProjectRootDirectory(value?: string): string {
  const normalized = value
    ?.trim()
    .replace(/^\.\//, "")
    .replace(/^\/+|\/+$/g, "");

  if (!normalized || normalized === ".") {
    return "";
  }

  return normalized.split(/[\\/]/).filter(Boolean).join("/");
}

/** Generate a URL-safe slug from a string */
export function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\w\s-]/g, "")
    .replace(/[\s_]+/g, "-")
    .slice(0, 100)
    .replace(/^-+|-+$/g, "");
}

/**
 * A POSIX-style environment variable NAME (letter/underscore, then
 * alphanumerics/underscores). Single source for the rule that was duplicated
 * across the connection service, the jobs runner, and the compose parser.
 */
export function isValidEnvKey(key: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(key);
}
