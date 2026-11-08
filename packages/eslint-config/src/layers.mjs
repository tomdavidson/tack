// ── Three layers: domain, app, infra ───────────────────────────
// Suffix convention: pricing.domain.ts, pricing.app.ts, postgres.infra.ts
// Promoted subdirs: domain/*.ts, app/*.ts, infra/*.ts
// Tests are a file type (*.spec.ts), not an architectural layer.

// ── Layer file globs ───────────────────────────────────────────
export const domainFiles = ['src/**/*.domain.ts', 'src/**/domain/**/*.ts']
export const appFiles = ['src/**/*.app.ts', 'src/**/app/**/*.ts']
// Composition root (main.ts / index.ts) is the imperative shell: wiring + IO.
export const infraFiles = [
  'src/**/*.infra.ts',
  'src/**/infra/**/*.ts',
  'src/cli/**/*.ts',
  'src/main.ts',
  'src/index.ts',
]
export const testFiles = ['src/**/*.spec.ts', 'src/**/*.test.ts', 'src/test/**/*.ts']
// Codec: the only files that may spell foreign identifiers (wire headers,
// external JSON keys) as property names. They describe external shapes with
// zod and export domain-named types + fromWire/toWire. Infra-side: imports
// domain, imported by infra and tests, never by app or domain.
export const codecFiles = ['src/**/*.codec.ts', 'src/**/codec/**/*.ts']

export const frameworkInfraFiles = ['**/integration.ts', '**/*.config.ts']

// ── Boundary enforcement ───────────────────────────────────────
// Three layers + tests. No shared/composition layers needed.
export const boundaryElements = [
  { type: 'domain', pattern: domainFiles },
  { type: 'app', pattern: appFiles },
  { type: 'infra', pattern: [...infraFiles, ...frameworkInfraFiles] },
  { type: 'codec', pattern: codecFiles },
  { type: 'test', pattern: testFiles },
]

// Dependency inversion: inner layers cannot import outer layers
export const boundaryRules = [
  { from: 'domain', allow: ['domain'] },
  { from: 'app', allow: ['domain', 'app'] },
  { from: 'codec', allow: ['domain', 'codec'] },
  { from: 'infra', allow: ['domain', 'app', 'infra', 'codec'] },
  { from: 'test', allow: ['domain', 'app', 'infra', 'codec', 'test'] },
]
