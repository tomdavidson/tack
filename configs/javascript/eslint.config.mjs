// Shipped by tack. Symlinked into the consumer repo root.
//
// Behavior:
//   - Always applies @tack/eslint-config.
//   - If the consumer's package.json lists 'astro' in dependencies or
//     devDependencies, additionally applies @tack/eslint-config-astro
//     via dynamic import. When astro is absent, the astro config package is
//     never loaded.
//
// The consumer root is found by walking up from process.cwd() to the nearest
// package.json, so eslint invoked from a subdirectory still resolves to the
// repo root.

import tsConfig from '@tack/eslint-config'
import { defineConfig } from 'eslint/config'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

function findConsumerRoot(start = process.cwd()) {
  let dir = resolve(start)
  while (true) {
    try {
      const pkgPath = resolve(dir, 'package.json')
      const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'))
      return { root: dir, pkg }
    } catch (e) {
      if (e.code !== 'ENOENT') throw e
      const parent = dirname(dir)
      if (parent === dir) {
        throw new Error(`eslint.config.mjs: no package.json found walking up from ${start}`)
      }
      dir = parent
    }
  }
}

const { root: tsconfigRootDir, pkg } = findConsumerRoot()
const isAstro = Boolean(pkg.dependencies?.astro || pkg.devDependencies?.astro)

const configs = [...tsConfig({ tsconfigRootDir })]

if (isAstro) {
  const { default: astroConfig } = await import('@tack/eslint-config-astro')
  configs.push(...astroConfig({ tsconfigRootDir }))
}

export default defineConfig(...configs)
