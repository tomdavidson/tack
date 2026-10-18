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
// _unsafeUnwrap and _unsafeUnwrapErr are enforced natively by oxlint via
// no-restricted-properties in oxlintrc.jsonc.
export const restrictedSyntax = ['error', {
  selector: ":function > Identifier.params[typeAnnotation.typeAnnotation.type='TSBooleanKeyword']",
  message: 'Boolean params are banned. Split into separate functions.',
}]

// ── Domain layer overrides ─────────────────────────────────────
// Domain IO import bans (no-restricted-imports) are enforced natively
// by oxlint in oxlintrc.jsonc.
export const domainRules = { 'functional/prefer-readonly-type': 'error' }

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
