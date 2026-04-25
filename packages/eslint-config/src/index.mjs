/**
 * @astro-bay/eslint-config
 *
 * ESLint flat config for TypeScript projects using clean architecture
 * with FP enforcement, boundary rules, and oxlint deduplication.
 * Also bundles oxlint + oxlint-tsgolint and the canonical oxlintrc.json.
 *
 * Usage:
 *   import tsConfig from '@astro-bay/eslint-config'
 *   import { defineConfig } from 'eslint/config'
 *   export default defineConfig(
 *     ...tsConfig({ tsconfigRootDir: import.meta.dirname }),
 *   )
 *
 * Usage (with astro config):
 *   import tsConfig from '@astro-bay/eslint-config'
 *   import astroConfig from '@astro-bay/eslint-config-astro'
 *   import { defineConfig } from 'eslint/config'
 *   export default defineConfig(
 *     ...tsConfig({ tsconfigRootDir: import.meta.dirname }),
 *     ...astroConfig({ tsconfigRootDir: import.meta.dirname }),
 *   )
 *
 * Usage (rules/layers only):
 *   import { functionalRules, infraRules } from '@astro-bay/eslint-config/rules'
 *   import { domainFiles, boundaryElements } from '@astro-bay/eslint-config/layers'
 *
 * The bundled oxlintrc.json can be extended by editor plugins:
 *   // root oxlintrc.json
 *   { "extends": ["./node_modules/@astro-bay/eslint-config/src/oxlintrc.json"] }
 */

import boundaries from 'eslint-plugin-boundaries'
import functional from 'eslint-plugin-functional'
import oxlint from 'eslint-plugin-oxlint'
import preferArrowFunctions from 'eslint-plugin-prefer-arrow-functions'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import tseslint from 'typescript-eslint'

import {
  arrowFunctionRules,
  domainRules,
  functionalRules,
  infraRules,
  restrictedSyntax,
  testRules,
} from './rules.mjs'

import { appFiles, boundaryElements, boundaryRules, domainFiles, infraFiles, testFiles } from './layers.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))

/** Absolute path to the bundled oxlintrc.json */
export const oxlintConfigPath = resolve(__dirname, 'oxlintrc.jsonc')

/**
 * @param {object} options
 * @param {string} options.tsconfigRootDir - Root dir for tsconfig resolution (use import.meta.dirname)
 * @param {string} [options.oxlintConfig] - Override path to oxlintrc.json (default: bundled)
 * @param {string[]} [options.files] - Source file globs
 * @param {string[]} [options.ignores] - Additional ignore patterns
 * @param {object} [options.rules] - Override/extend global rules
 * @returns {import('eslint').Linter.Config[]}
 */
const tsConfig = options => {
  const {
    tsconfigRootDir,
    oxlintConfig = oxlintConfigPath,
    files: sourceFiles = ['src/**/*.ts'],
    ignores: extraIgnores = [],
    rules: ruleOverrides = {},
  } = options

  const configs = [
    { ignores: ['node_modules/**', 'dist/**', 'eslint.config.mjs', ...extraIgnores] },

    // Global: all source files (app-layer defaults)
    {
      name: '@astro-bay/eslint-config/global',
      files: sourceFiles,
      languageOptions: { parser: tseslint.parser, parserOptions: { project: true, tsconfigRootDir } },
      plugins: { functional, 'prefer-arrow-functions': preferArrowFunctions, boundaries },
      settings: { 'boundaries/elements': boundaryElements },
      rules: {
        ...functionalRules,
        ...arrowFunctionRules,
        'no-restricted-syntax': restrictedSyntax,
        'boundaries/element-types': ['error', { default: 'disallow', rules: boundaryRules }],
        ...ruleOverrides,
      },
    },

    // Domain: tighten for purity
    { name: '@astro-bay/eslint-config/domain', files: domainFiles, rules: domainRules },

    // Infrastructure: imperative shell allowances
    { name: '@astro-bay/eslint-config/infra', files: infraFiles, rules: infraRules },

    // Tests: fully relax FP rules
    { name: '@astro-bay/eslint-config/tests', files: testFiles, rules: testRules },

    // Deduplicate: turn off anything oxlint already handles
    ...oxlint.buildFromOxlintConfigFile(oxlintConfig),
  ]

  return configs
}

export default tsConfig
export { tsConfig }

export {
  arrowFunctionRules,
  domainRules,
  functionalRules,
  infraRules,
  restrictedSyntax,
  testRules,
} from './rules.mjs'

export {
  appFiles,
  boundaryElements,
  boundaryRules,
  domainFiles,
  frameworkInfraFiles,
  infraFiles,
  testFiles,
} from './layers.mjs'
