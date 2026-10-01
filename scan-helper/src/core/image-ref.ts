/**
 * Strip the parts of a reference that say WHERE an image came from, leaving the
 * repository that says WHAT it is.
 *
 * The registry rule is Docker's own (`reference.splitDockerDomain`): the first path
 * component is a registry host if it contains a `.` or a `:`, or is exactly
 * `localhost`. Anything else is a Docker Hub namespace and is KEPT — which is what
 * keeps `acme/mysql-proxy` from ever reading as MySQL, and `ghcr.io/someorg/postgres`
 * from reading as PostgreSQL once `ghcr.io` is gone.
 *
 * `library` is then dropped from any non-final position: it is Docker Hub's reserved
 * namespace for official images, so `docker.io/library/postgres` IS `postgres` by
 * definition. Non-final rather than leading, because the public mirrors keep it behind
 * their own alias (`public.ecr.aws/docker/library/postgres`).
 *
 * A `@sha256:…` digest is removed first. It is not part of the repository, and left in
 * place it defeats the `(?::|$)` anchor — so a digest-pinned `postgres@sha256:…`, which
 * is what a compose file that pins by digest produces, read as "not a database" and
 * silently took a crash-consistent volume snapshot instead of a dump.
 */
export function normalizeImageRef(image: string): string {
  let ref = image.trim();
  const at = ref.indexOf("@");
  if (at > 0) ref = ref.slice(0, at);
  const parts = ref.split("/");
  const first = parts[0] ?? "";
  if (parts.length > 1 && (first.includes(".") || first.includes(":") || first === "localhost")) {
    parts.shift();
  }
  const library = parts.lastIndexOf("library");
  if (library >= 0 && library < parts.length - 1) parts.splice(0, library + 1);
  return parts.join("/");
}

/** OCI/Docker distribution reference limits. */
const MAX_IMAGE_NAME_LENGTH = 255;
const MAX_IMAGE_TAG_LENGTH = 128;

/** A repository path component from the distribution/reference grammar. */
const IMAGE_PATH_COMPONENT_RE = /^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*$/;
/** A tag from the distribution/reference grammar. */
const IMAGE_TAG_RE = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/;
/** A digest algorithm and encoded value from the OCI descriptor grammar. */
const IMAGE_DIGEST_RE = /^([A-Za-z][A-Za-z0-9]*(?:[+._-][A-Za-z][A-Za-z0-9]*)*):([A-Za-z0-9=_-]+)$/;
// Registry DNS names are case-insensitive and the distribution grammar permits
// either case. Only repository path components are required to be lowercase.
const IMAGE_DOMAIN_LABEL_RE = /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/;

/**
 * Validate a concrete OCI/Docker image reference.
 *
 * Returns an actionable message rather than throwing so API schemas, CLI input
 * and dashboard forms can share the same rule and present it in their own shape.
 * The release renderer below turns the message into an exception because a bad
 * frozen artifact must stop before a pull/deploy is attempted.
 *
 * This intentionally validates more than "contains a slash and colon": schemes,
 * uppercase repository names, empty components, traversal-ish separators,
 * malformed registry ports, overlong tags and malformed digests are all rejected
 * here rather than delegated to a Docker daemon with a target-specific error.
 */
export function validateImageReference(ref: string): string | null {
  if (typeof ref !== "string") return "Container image reference must be a string.";
  if (!ref) return "Container image reference cannot be empty.";
  if (ref !== ref.trim()) return "Container image reference cannot have surrounding whitespace.";
  if (/\s/.test(ref))
    return `Container image reference ${JSON.stringify(ref)} cannot contain whitespace.`;
  if (ref.includes("\0"))
    return `Container image reference ${JSON.stringify(ref)} contains a NUL byte.`;
  if (ref.includes("://")) {
    return `Container image reference ${JSON.stringify(ref)} must not include a URL scheme.`;
  }

  const at = ref.indexOf("@");
  if (at !== -1 && at !== ref.lastIndexOf("@")) {
    return `Container image reference ${JSON.stringify(ref)} contains more than one digest separator (@).`;
  }

  const nameAndTag = at === -1 ? ref : ref.slice(0, at);
  const digest = at === -1 ? null : ref.slice(at + 1);
  if (!nameAndTag)
    return `Container image reference ${JSON.stringify(ref)} is missing a repository name.`;
  if (digest !== null) {
    const parsed = IMAGE_DIGEST_RE.exec(digest);
    if (!parsed) {
      return `Container image reference ${JSON.stringify(ref)} has an invalid OCI digest.`;
    }
    // The generic OCI grammar permits algorithms other than sha256. For the
    // overwhelmingly common sha256 form, enforce its real encoded length so a
    // truncated digest is not accepted as a deployable reference.
    if (parsed[1]!.toLowerCase() === "sha256" && !/^[a-fA-F0-9]{64}$/.test(parsed[2]!)) {
      return `Container image reference ${JSON.stringify(ref)} has an invalid sha256 digest (expected 64 hexadecimal characters).`;
    }
  }

  const lastSlash = nameAndTag.lastIndexOf("/");
  const lastColon = nameAndTag.lastIndexOf(":");
  const hasTag = lastColon > lastSlash;
  const name = hasTag ? nameAndTag.slice(0, lastColon) : nameAndTag;
  const tag = hasTag ? nameAndTag.slice(lastColon + 1) : null;

  if (!name)
    return `Container image reference ${JSON.stringify(ref)} is missing a repository name.`;
  if (name.length > MAX_IMAGE_NAME_LENGTH) {
    return `Container image repository name is too long (${name.length}; maximum ${MAX_IMAGE_NAME_LENGTH}).`;
  }
  if (tag !== null) {
    if (!tag) return `Container image reference ${JSON.stringify(ref)} has an empty tag.`;
    if (tag.length > MAX_IMAGE_TAG_LENGTH || !IMAGE_TAG_RE.test(tag)) {
      return `Container image reference ${JSON.stringify(ref)} has an invalid tag; tags must be 1-${MAX_IMAGE_TAG_LENGTH} ASCII letters, digits, underscores, periods, or hyphens and cannot start with a period or hyphen.`;
    }
  }

  const parts = name.split("/");
  if (parts.some((part) => !part)) {
    return `Container image reference ${JSON.stringify(ref)} contains an empty repository path component.`;
  }

  // Docker treats the first component as a registry only when it looks like a
  // host. A bare `org/image` therefore validates both components as repository
  // path segments and resolves through Docker Hub.
  const first = parts[0]!;
  const hasRegistry =
    parts.length > 1 &&
    (first.includes(".") || first.includes(":") || first === "localhost" || first.startsWith("["));
  const path = hasRegistry ? parts.slice(1) : parts;
  if (path.length === 0 || path.some((part) => !IMAGE_PATH_COMPONENT_RE.test(part))) {
    return `Container image reference ${JSON.stringify(ref)} has an invalid repository path; repository names must be lowercase OCI path components.`;
  }

  if (hasRegistry) {
    const registryError = validateImageRegistry(first);
    if (registryError) return `Container image reference ${JSON.stringify(ref)} ${registryError}`;
  }

  return null;
}


/**
 * Validate a Docker-compatible bracketed IPv6 registry host without importing
 * Node-only networking APIs into the shared dashboard/core bundle.
 */
function isValidBracketedIpv6Host(host: string): boolean {
  // Distribution references permit only hexadecimal IPv6 notation here (no
  // zone identifiers or dotted IPv4 tail). The URL parser then verifies the
  // compression and segment structure that a character class cannot express.
  if (!/^\[[0-9a-fA-F:]+\]$/.test(host)) return false;
  try {
    const parsed = new URL(`http://${host}/`);
    return parsed.hostname.startsWith("[") && parsed.hostname.endsWith("]");
  } catch {
    return false;
  }
}

/** Validate the optional registry component, including a numeric TCP port. */
function validateImageRegistry(registry: string): string | null {
  let host = registry;
  let port: string | null = null;

  if (registry.startsWith("[")) {
    const close = registry.indexOf("]");
    if (close <= 1) return "has an invalid bracketed IPv6 registry host.";
    host = registry.slice(0, close + 1);
    const rest = registry.slice(close + 1);
    if (rest) {
      if (!rest.startsWith(":")) return "has invalid characters after its registry host.";
      port = rest.slice(1);
    }
    if (!isValidBracketedIpv6Host(host)) {
      return "has an invalid bracketed IPv6 registry host.";
    }
  } else {
    const colon = registry.lastIndexOf(":");
    if (colon !== -1) {
      host = registry.slice(0, colon);
      port = registry.slice(colon + 1);
    }
    if (!host) return "is missing its registry host.";
    const labels = host.split(".");
    if (labels.some((label) => !IMAGE_DOMAIN_LABEL_RE.test(label))) {
      return "has an invalid registry hostname.";
    }
  }

  if (port !== null) {
    if (!/^\d+$/.test(port)) return "has a non-numeric registry port.";
    const value = Number(port);
    if (value < 1 || value > 65535) return "has a registry port outside 1-65535.";
  }
  return null;
}

