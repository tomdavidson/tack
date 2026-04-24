import tsConfig from '@astro-bay/eslint-config'
import astroConfig from '@astro-bay/eslint-config-astro'
import { defineConfig } from 'eslint/config'

export default defineConfig(
  ...tsConfig({ tsconfigRootDir: import.meta.dirname }),
  ...astroConfig({ tsconfigRootDir: import.meta.dirname }),
)
