// ── Three layers: domain, app, infra ───────────────────────────
// Suffix convention: pricing.domain.ts, pricing.app.ts, postgres.infra.ts
// Promoted subdirs: domain/*.ts, app/*.ts, infra/*.ts
// Tests are a file type (*.spec.ts), not an architectural layer.

// ── Layer file globs ───────────────────────────────────────────
export const domainFiles = ['src/**/*.domain.ts', 'src/**/domain/**/*.ts']
export const appFiles = ['src/**/*.app.ts', 'src/**/app/**/*.ts']
export const infraFiles = ['src/**/*.infra.ts', 'src/**/infra/**/*.ts', 'src/cli/**/*.ts']
export const testFiles = ['src/**/*.spec.ts', 'src/**/*.test.ts', 'src/test/**/*.ts']

export const frameworkInfraFiles = ['**/integration.ts', '**/*.config.ts']

// ── Boundary enforcement ───────────────────────────────────────
// Three layers + tests. No shared/composition layers needed.
export const boundaryElements = [
  { type: 'domain', pattern: domainFiles },
  { type: 'app', pattern: appFiles },
  { type: 'infra', pattern: [...infraFiles, ...frameworkInfraFiles] },
  { type: 'test', pattern: testFiles },
]

// Dependency inversion: inner layers cannot import outer layers
export const boundaryRules = [
  { from: 'domain', allow: ['domain'] },
  { from: 'app', allow: ['domain', 'app'] },
  { from: 'infra', allow: ['domain', 'app', 'infra'] },
  { from: 'test', allow: ['domain', 'app', 'infra', 'test'] },
]
