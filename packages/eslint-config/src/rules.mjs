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

// ── Complexity (oxlint has no cognitive-complexity rule) ────────
// Cognitive complexity is the lintable proxy for "one idea" (toms-clean-code.md
// Function Shape). oxlint carries the cyclomatic backstop (complexity: 10),
// nesting (max-depth: 2), and length (max-lines-per-function: 60).
export const complexityRules = { 'sonarjs/cognitive-complexity': ['error', 8] }

// ── Naming (lang-typescript.md Naming) ───────────────────────────
// Casing is enforced here; the words are governed by toms-clean-code.md.
// Strict formats: acronyms are words (HttpClient, userId), never runs of
// capitals (HTTPClient, userID). Plain PascalCase/camelCase accept both and
// leave the choice to the author; Strict* removes the choice.
const namingSelectors = [
  { selector: 'default', format: ['strictCamelCase'], leadingUnderscore: 'allow' },
  { selector: 'import', format: null },
  { selector: 'variable', format: ['strictCamelCase', 'UPPER_CASE'], leadingUnderscore: 'allow' },
  { selector: 'variable', modifiers: ['destructured'], format: null },
  { selector: 'function', format: ['strictCamelCase'] },
  { selector: 'parameter', format: ['strictCamelCase'], leadingUnderscore: 'allow' },
  { selector: 'parameter', modifiers: ['destructured'], format: null },
  { selector: 'typeLike', format: ['StrictPascalCase'] },
  { selector: 'typeParameter', format: ['StrictPascalCase'] },
  { selector: 'enumMember', format: ['StrictPascalCase'] },
  { selector: 'interface', format: ['StrictPascalCase'], custom: { regex: '^I[A-Z]', match: false } },
  // Keys that cannot be identifiers ('content-type'). Does NOT cover foreign
  // names that happen to be valid identifiers (ThreadID, Authorization):
  // dprint strips their quotes and this modifier no longer matches. Those
  // belong in codec files (codecRules) or in string constants, never as keys.
  { selector: 'objectLiteralProperty', modifiers: ['requiresQuotes'], format: null },
  {
    selector: ['variable', 'parameter', 'property'],
    types: ['boolean'],
    format: ['StrictPascalCase'],
    prefix: ['is', 'has', 'can', 'should'],
    leadingUnderscore: 'allow',
  },
]

export const namingRules = { '@typescript-eslint/naming-convention': ['error', ...namingSelectors] }

// ── Codec files: foreign identifiers as property names ─────────
// *.codec.ts is the one place an external shape (HTTP header, query param,
// third-party JSON key) may appear as a property. Individual selectors
// (objectLiteralProperty, typeProperty) outrank the grouped boolean-prefix
// selector, so `success: z.boolean()` passes here and nowhere else. The
// codec exports domain-named types; the raw z.infer never leaves the file.
export const codecRules = {
  '@typescript-eslint/naming-convention': ['error', ...namingSelectors, {
    selector: ['objectLiteralProperty', 'typeProperty'],
    format: null,
  }],
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
  'sonarjs/cognitive-complexity': ['error', 12],
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
  'sonarjs/cognitive-complexity': 'off',
  '@typescript-eslint/naming-convention': 'off',
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
