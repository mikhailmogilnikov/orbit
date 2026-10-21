/** What the site says about releases, read from GitHub once per build. */

export const REPO = "https://github.com/mikhailmogilnikov/orbit";
const API = "https://api.github.com/repos/mikhailmogilnikov/orbit/releases";

export interface Release {
  version: string;
  date: Date;
  url: string;
  body: string;
  /** The app's zip: its download link and size */
  zip?: { url: string; bytes: number };
}

interface GitHubRelease {
  tag_name: string;
  published_at: string;
  html_url: string;
  body: string | null;
  draft: boolean;
  prerelease: boolean;
  assets: { name: string; size: number; browser_download_url: string }[];
}

let cached: Promise<Release[]> | undefined;

/** Newest first. Empty when GitHub can't be reached, so a build never fails on it. */
export function releases(): Promise<Release[]> {
  cached ??= (async () => {
    try {
      const headers: Record<string, string> = { Accept: "application/vnd.github+json" };
      if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
      const response = await fetch(`${API}?per_page=50`, { headers });
      if (!response.ok) return [];
      const list = (await response.json()) as GitHubRelease[];
      return list
        .filter((r) => !r.draft && !r.prerelease)
        .map((r) => {
          const zip = r.assets.find((a) => /^Orbit-.*\.zip$/.test(a.name));
          return {
            version: r.tag_name.replace(/^v/, ""),
            date: new Date(r.published_at),
            url: r.html_url,
            body: r.body ?? "",
            zip: zip && { url: zip.browser_download_url, bytes: zip.size },
          };
        });
    } catch {
      return [];
    }
  })();
  return cached;
}

export async function latest() {
  const [newest] = await releases();
  return {
    version: newest?.version,
    // Straight to the zip when there is one, else the releases page
    download: newest?.zip?.url ?? `${REPO}/releases/latest`,
    megabytes: newest?.zip ? Math.round(newest.zip.bytes / 1_000_000) : undefined,
  };
}
