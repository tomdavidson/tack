// .github/actions/gh-settings/merge.spec.js
//
// Layer 1 co-located tests. Node builtin runner so this is runnable with
// `node --test merge.spec.js` with zero install.

const { describe, it } = require('node:test')
const assert = require('node:assert/strict')
const { _internals } = require('./merge.js')

const { deepMerge, collectKeyPaths, stripPath, stripEnforcedKeys, buildBlueprint } = _internals

describe('deepMerge', () => {
  it('should return override when base is not an object', () => {
    assert.equal(deepMerge(1, 2), 2)
  })

  it('should deep-merge nested objects', () => {
    const out = deepMerge({ a: { x: 1, y: 2 }, b: 1 }, { a: { y: 9, z: 3 } })
    assert.deepEqual(out, { a: { x: 1, y: 9, z: 3 }, b: 1 })
  })

  it('should replace arrays wholesale', () => {
    const out = deepMerge({ a: [1, 2] }, { a: [3] })
    assert.deepEqual(out, { a: [3] })
  })
})

describe('collectKeyPaths', () => {
  it('should return dotted paths for leaf keys', () => {
    const out = collectKeyPaths({ a: { b: 1, c: { d: 2 } }, e: 3 })
    assert.deepEqual(out.sort(), ['a.b', 'a.c.d', 'e'])
  })
})

describe('stripPath', () => {
  it('should remove a nested key when present', () => {
    const { obj, stripped } = stripPath({ a: { b: 1, c: 2 } }, 'a.b')
    assert.equal(stripped, true)
    assert.deepEqual(obj, { a: { c: 2 } })
  })

  it('should report stripped false when path missing', () => {
    const { obj, stripped } = stripPath({ a: { c: 2 } }, 'a.b')
    assert.equal(stripped, false)
    assert.deepEqual(obj, { a: { c: 2 } })
  })
})

describe('stripEnforcedKeys', () => {
  it('should strip all enforced leaf paths from overrides', () => {
    const enforced = { visibility: 'private', security: { secret_scanning: true } }
    const overrides = {
      visibility: 'public',
      security: { secret_scanning: false, vulnerability_alerts: false },
      topics: ['a'],
    }
    const { overrides: out, stripped } = stripEnforcedKeys(overrides, enforced)
    assert.deepEqual(stripped.sort(), ['security.secret_scanning', 'visibility'])
    assert.deepEqual(out, { security: { vulnerability_alerts: false }, topics: ['a'] })
  })
})

describe('buildBlueprint', () => {
  it('should apply defaults, then stripped overrides, then enforced last', () => {
    const enforced = { visibility: 'private' }
    const defaults = { visibility: 'internal', has_issues: true }
    const overrides = { has_issues: false, description: 'x' }
    const out = buildBlueprint({ enforced, defaults, overrides, repoName: 'astro-bay', owner: 'tomdavidson' })
    assert.deepEqual(out.repo, {
      owner: 'tomdavidson',
      name: 'astro-bay',
      visibility: 'private',
      has_issues: false,
      description: 'x',
    })
  })
})
