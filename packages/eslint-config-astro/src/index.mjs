/**
 * @astro-bay/eslint-config-astro
 *
 * ESLint flat config for .astro files. Treats Astro as the infrastructure/view
 * layer with FP relaxations, structural complexity limits, unicorn, and node rules.
 *
 * Usage:
 *   import astroConfig from '@astro-bay/eslint-config-astro'
 *   import { defineConfig } from 'eslint/config'
 *   export default defineConfig(
 *     ...astroConfig({ tsconfigRootDir: import.meta.dirname }),
 *   )
 *
 * Usage (composed into a larger config):
 *   import tsConfig from '@astro-bay/eslint-config'
 *   import astroConfig from '@astro-bay/eslint-config-astro'
 *   import { defineConfig } from 'eslint/config'
 *   export default defineConfig(
 *     ...tsConfig({ tsconfigRootDir: import.meta.dirname }),
 *     ...astroConfig({ tsconfigRootDir: import.meta.dirname }),
 *   )
 *
 * Usage (rules only, bring your own parser):
 *   import { astroFrontmatterRules } from '@astro-bay/eslint-config-astro/rules'
 */

import astroPlugin from 'eslint-plugin-astro'
import functional from 'eslint-plugin-functional'
import nodePlugin from 'eslint-plugin-n'
import unicorn from 'eslint-plugin-unicorn'
import tseslint from 'typescript-eslint'

import { astroClientScriptRules, astroFrontmatterRules } from './rules.mjs'

/**
 * @param {object} [options]
 * @param {string} [options.tsconfigRootDir] - Root dir for tsconfig resolution
 * @param {string[]} [options.files] - Additional file globs to match
 * @param {object} [options.rules] - Override/extend frontmatter rules
 * @param {object} [options.clientScriptRules] - Override/extend client script rules
 * @returns {import('eslint').Linter.Config[]}
 */
const astroConfig = (options = {}) => {
  const {
    tsconfigRootDir,
    files: extraFiles = [],
    rules: ruleOverrides = {},
    clientScriptRules: clientOverrides = {},
  } = options

  const astroFiles = ['**/*.astro', ...extraFiles]

  const baseConfigs = astroPlugin.configs['flat/recommended']

  const parserOptions = { extraFileExtensions: ['.astro'], parser: tseslint.parser, project: true }

  if (tsconfigRootDir) {
    parserOptions.tsconfigRootDir = tsconfigRootDir
  }

  const clientParserOptions = { project: true }

  if (tsconfigRootDir) {
    clientParserOptions.tsconfigRootDir = tsconfigRootDir
  }

  const pluginMap = { functional, unicorn, n: nodePlugin }

  const configs = [
    ...baseConfigs,

    // Astro frontmatter (the --- block)
    {
      name: '@astro-bay/eslint-config-astro/frontmatter',
      files: astroFiles,
      languageOptions: { parserOptions },
      plugins: { ...pluginMap },
      rules: { ...astroFrontmatterRules, ...ruleOverrides },
    },

    // Client-side <script> tags extracted by eslint-plugin-astro
    {
      name: '@astro-bay/eslint-config-astro/client-scripts',
      files: ['**/*.astro/*.ts', '**/*.astro/*.js'],
      languageOptions: { parser: tseslint.parser, parserOptions: clientParserOptions },
      plugins: { ...pluginMap },
      rules: { ...astroClientScriptRules, ...clientOverrides },
    },
  ]

  return configs
}

export default astroConfig
export { astroConfig }

export {
  astroClientScriptRules,
  astroFrontmatterRules,
  boundaryRules,
  functionalRules,
  hygieneRules,
  immutabilityRules,
  nodeRules,
  structuralRules,
  unicornRules,
} from './rules.mjs'
