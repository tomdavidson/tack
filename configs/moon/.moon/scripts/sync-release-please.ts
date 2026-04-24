/**
 * sync-release-please.ts
 *
 * Keeps release-please-config.json and .release-please-manifest.json in sync
 * with the actual plugin packages discovered via `moon query projects`.
 *
 * How it works:
 * 1. Shells out to `moon query projects` to get every project in the workspace.
 *    (moon query already outputs JSON, no --json flag needed)
 * 2. Filters to projects whose source path starts with "plugins/".
 * 3. For each plugin, reads its package.json to get the current version.
 * 4. Ensures the plugin path exists as a key in both release-please files.
 *    - config: adds an empty override object (inherits top-level defaults).
 *    - manifest: uses the version from package.json, or "0.1.0" if missing.
 * 5. Removes entries from both files for plugins that no longer exist.
 * 6. Writes the updated files back to disk.
 *
 * Run via: moon run root:sync-release
 * CI usage: run with --check flag to fail if files are stale (no writes).
 */
import { execSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = join(new URL('.', import.meta.url).pathname, '..')
const CHECK = process.argv.includes('--check')

type MoonProject = { id: string; source: string }
type MoonQueryResult = { projects: ReadonlyArray<MoonProject> }

const graph: MoonQueryResult = JSON.parse(execSync('moon query projects', { cwd: ROOT, encoding: 'utf-8' }))

const pluginPaths = graph.projects.filter(p => p.source.startsWith('plugins/')).map(p => p.source).sort()

const readVersion = (source: string): string => {
  try {
    const pkg = JSON.parse(readFileSync(join(ROOT, source, 'package.json'), 'utf-8'))
    return typeof pkg.version === 'string' ? pkg.version : '0.1.0'
  } catch {
    return '0.1.0'
  }
}

const configPath = join(ROOT, 'release-please-config.json')
const manifestPath = join(ROOT, '.release-please-manifest.json')

const config = JSON.parse(readFileSync(configPath, 'utf-8'))
const manifest = JSON.parse(readFileSync(manifestPath, 'utf-8'))

const knownPaths = new Set(pluginPaths)

// Add missing plugins
for (const path of pluginPaths) {
  config.packages ??= {}
  config.packages[path] ??= {}
  manifest[path] ??= readVersion(path)
}

// Remove stale entries (plugins that were deleted)
for (const key of Object.keys(config.packages ?? {})) {
  if (key.startsWith('plugins/') && !knownPaths.has(key)) {
    delete config.packages[key]
    delete manifest[key]
    console.log(`Removed stale: ${key}`)
  }
}

const nextConfig = JSON.stringify(config, null, 2) + '\n'
const nextManifest = JSON.stringify(manifest, null, 2) + '\n'

const currentConfig = readFileSync(configPath, 'utf-8')
const currentManifest = readFileSync(manifestPath, 'utf-8')

if (nextConfig === currentConfig && nextManifest === currentManifest) {
  console.log('release-please files are up to date.')
  process.exit(0)
}

if (CHECK) {
  console.error('release-please files are stale. Run: moon run root:sync-release')
  console.error('Expected plugins:', pluginPaths.join(', '))
  process.exit(1)
}

writeFileSync(configPath, nextConfig)
writeFileSync(manifestPath, nextManifest)
console.log('Synced release-please for:', pluginPaths.join(', '))
