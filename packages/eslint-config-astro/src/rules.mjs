// ─────────────────────────────────────────────────────────────
// Structural & Complexity (mirrors oxlint infra overrides)
// Astro frontmatter is evaluated as a single function scope,
// so we use max-statements instead of max-lines-per-function.
// ─────────────────────────────────────────────────────────────
export const structuralRules = {
  'max-depth': ['warn', { max: 3 }],
  'complexity': ['warn', { max: 8 }],
  'max-params': ['error', { max: 3 }],
  'no-else-return': 'error',
  'no-nested-ternary': 'error',
  'max-statements': ['warn', 15, { ignoreTopLevelFunctions: true }],
}

// ─────────────────────────────────────────────────────────────
// Functional (aligned with infra layer relaxations)
// Astro is the imperative shell. try/catch and throw are
// expected for HTTP control flow (Astro.redirect, error pages).
// Side effects are expected (Astro.cookies, Astro.locals).
// ─────────────────────────────────────────────────────────────
export const functionalRules = {
  'functional/no-let': 'warn',
  'functional/no-loop-statements': 'warn',
  'functional/no-try-statements': 'off',
  'functional/no-throw-statements': 'off',
  'functional/no-expression-statements': 'off',
  'functional/no-return-void': 'off',
  'functional/immutable-data': 'off',
  'functional/no-classes': 'off',
  'functional/no-this-expressions': 'off',
  'functional/prefer-readonly-type': 'off',
}

// ─────────────────────────────────────────────────────────────
// Unicorn (declarative iteration and modern JS)
// Keeps array method preferences from the global config.
// forEach is allowed (infra relaxation).
// ─────────────────────────────────────────────────────────────
export const unicornRules = {
  'unicorn/no-null': 'warn',
  'unicorn/no-useless-undefined': 'warn',
  'unicorn/prefer-array-find': 'error',
  'unicorn/prefer-array-some': 'error',
  'unicorn/prefer-array-flat-map': 'error',
  'unicorn/prefer-array-index-of': 'error',
  'unicorn/prefer-set-has': 'warn',
  'unicorn/prefer-ternary': ['warn', 'only-single-line'],
  'unicorn/prefer-node-protocol': 'error',
  'unicorn/no-negated-condition': 'warn',
  'unicorn/error-message': 'error',
  'unicorn/throw-new-error': 'error',
  'unicorn/prefer-type-error': 'warn',
  'unicorn/no-static-only-class': 'error',
  'unicorn/no-empty-file': 'error',
  'unicorn/prefer-spread': 'warn',
  // Infra relaxation: forEach allowed in view/IO layer
  'unicorn/no-array-for-each': 'off',
  'unicorn/no-array-reduce': 'off',
}

// ─────────────────────────────────────────────────────────────
// Node (environment & module hygiene)
// process.env is allowed: Astro is the outermost shell.
// ─────────────────────────────────────────────────────────────
export const nodeRules = {
  'n/no-process-env': 'off',
  'n/no-exports-assign': 'error',
  'n/no-new-require': 'error',
}

// ─────────────────────────────────────────────────────────────
// Immutability (baseline, relaxed for infra)
// ─────────────────────────────────────────────────────────────
export const immutabilityRules = { 'no-var': 'error', 'prefer-const': 'error' }

// ─────────────────────────────────────────────────────────────
// General hygiene
// ─────────────────────────────────────────────────────────────
export const hygieneRules = {
  'no-console': ['warn', { allow: ['warn', 'error'] }],
  'no-debugger': 'error',
  'no-eval': 'error',
  'eqeqeq': 'error',
  'no-implicit-coercion': 'error',
  'no-throw-literal': 'error',
  'prefer-promise-reject-errors': 'error',
}

// ─────────────────────────────────────────────────────────────
// Architectural boundaries
// Nudge: keep .astro files thin. Extract logic to .app.ts/.infra.ts.
// Ban direct DB/IO imports in the view layer.
// ─────────────────────────────────────────────────────────────
export const boundaryRules = {
  'no-restricted-syntax': ['warn', {
    selector: 'Program > FunctionDeclaration',
    message: 'Extract functions to a .app.ts or .infra.ts file.',
  }, {
    selector: 'Program > VariableDeclaration > VariableDeclarator > ArrowFunctionExpression[params.length>0]',
    message: 'Extract parameterized logic to a separate TypeScript file.',
  }],
  'no-restricted-imports': ['warn', {
    patterns: [{
      group: ['pg', 'mysql*', 'redis', 'ioredis', 'mongoose', '@prisma/*', 'kysely'],
      message: 'View layer should not import database drivers directly. Delegate to .app.ts.',
    }, {
      group: ['fs', 'fs/*', 'child_process'],
      message: 'No raw Node IO in the view layer. Delegate to .infra.ts or .app.ts.',
    }],
  }],
}

// ─────────────────────────────────────────────────────────────
// Composed: all Astro frontmatter rules
// ─────────────────────────────────────────────────────────────
export const astroFrontmatterRules = {
  ...structuralRules,
  ...functionalRules,
  ...unicornRules,
  ...nodeRules,
  ...immutabilityRules,
  ...hygieneRules,
  ...boundaryRules,
}

// ─────────────────────────────────────────────────────────────
// Client-side <script> rules (tighter statements, no console restriction)
// ─────────────────────────────────────────────────────────────
export const astroClientScriptRules = {
  ...astroFrontmatterRules,
  'max-statements': ['warn', 10],
  'no-console': 'off',
  // No architectural boundary enforcement in client scripts
  'no-restricted-syntax': 'off',
  'no-restricted-imports': 'off',
}
