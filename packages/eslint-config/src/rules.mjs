// ── Functional rules (global defaults) ─────────────────────────
// Core FP rules that oxlint cannot replicate.
// ESLint owns all functional/* enforcement.
export const functionalRules = {
  'functional/no-loop-statements': 'error',
  'functional/no-try-statements': 'error',
  'functional/no-throw-statements': 'error',
  'functional/no-let': ['error', { allowInForLoopInit: false }],
  'functional/no-classes': 'error',
  'functional/no-this-expressions': 'error',
  'functional/immutable-data': ['warn', { ignoreImmediateMutation: true, ignoreClasses: true }],
  'functional/prefer-readonly-type': 'warn',
  'functional/no-expression-statements': ['error', {
    ignoreVoid: true,
    ignoreCodePattern: ['^expect', '^assert'],
  }],
  'functional/no-return-void': 'error',
}

// ── Arrow function enforcement ─────────────────────────────────
// ESLint owns the semantic rule (must use arrows).
// dprint owns arrow formatting (parens, wrapping).
export const arrowFunctionRules = {
  'prefer-arrow-functions/prefer-arrow-functions': ['error', {
    allowNamedFunctions: false,
    classPropertiesAllowed: false,
    disallowPrototype: true,
    returnStyle: 'unchanged',
    singleReturnOnly: false,
  }],
}

// ── AST selector bans (oxlint cannot do ESQuery selectors) ─────
export const restrictedSyntax = ['error', {
  selector: ":function > Identifier.params[typeAnnotation.typeAnnotation.type='TSBooleanKeyword']",
  message: 'Boolean params are banned. Split into separate functions.',
}, {
  selector: "CallExpression[callee.property.name='_unsafeUnwrap']",
  message: 'Use .map(), .andThen(), or .match() instead.',
}, {
  selector: "CallExpression[callee.property.name='_unsafeUnwrapErr']",
  message: 'Use .mapErr(), .andThen(), or .match() instead.',
}]

// ── Domain purity: ban IO imports in domain files ──────────────
export const domainImportBans = {
  patterns: [{
    group: ['fs', 'fs/*', 'path', 'http', 'https', 'net', 'child_process', 'crypto'],
    message: 'Domain must be pure. No Node.js IO.',
  }, {
    group: ['express', 'fastify', 'koa', 'hono', 'elysia'],
    message: 'Domain must be pure. No HTTP frameworks.',
  }, {
    group: ['pg', 'mysql*', 'redis', 'ioredis', 'mongoose', '@prisma/*', 'kysely'],
    message: 'Domain must be pure. No database drivers.',
  }, {
    group: ['@aws-sdk/*', '@azure/*', '@google-cloud/*'],
    message: 'Domain must be pure. No cloud SDKs.',
  }],
}

// ── Domain layer overrides ─────────────────────────────────────
export const domainRules = {
  'no-restricted-imports': ['error', domainImportBans],
  'functional/prefer-readonly-type': 'error',
}

// ── Infrastructure: imperative shell allowances ────────────────
export const infraRules = {
  'functional/no-let': 'warn',
  'functional/no-loop-statements': 'warn',
  'functional/no-try-statements': 'off',
  'functional/no-throw-statements': 'off',
  'functional/no-expression-statements': 'off',
  'functional/no-return-void': 'off',
  'functional/immutable-data': 'off',
  'functional/no-classes': ['error', {
    ignoreIdentifierPattern: '^.*(Controller|Adapter|Module|Client|Provider|Gateway)$',
  }],
  'functional/no-this-expressions': 'off',
}

// ── Tests: fully relax FP rules ──────────────────────────────
export const testRules = {
  'functional/no-let': 'off',
  'functional/no-loop-statements': 'off',
  'functional/no-try-statements': 'off',
  'functional/no-throw-statements': 'off',
  'functional/no-expression-statements': 'off',
  'functional/no-return-void': 'off',
  'functional/immutable-data': 'off',
  'functional/no-classes': 'off',
  'functional/no-this-expressions': 'off',
  'no-restricted-syntax': 'off',
}
