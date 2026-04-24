// .github/actions/gh-settings/merge.js
//
// Reads enforced, defaults, and the caller repo's override file, then produces
// a final blueprint as blueprint.auto.tfvars.json for OpenTofu. Enforced keys
// are stripped from the override before merging and reapplied last so policy
// always wins.

const fs = require('node:fs')
const path = require('node:path')
const yaml = require('js-yaml')

const isPlainObject = value => value !== null && typeof value === 'object' && !Array.isArray(value)

const deepMerge = (base, over) => {
  if (!isPlainObject(base) || !isPlainObject(over)) return over ?? base
  const out = { ...base }
  for (const key of Object.keys(over)) {
    out[key] = isPlainObject(base[key]) && isPlainObject(over[key]) ?
      deepMerge(base[key], over[key]) :
      over[key]
  }
  return out
}

const collectKeyPaths = (obj, prefix = '') => {
  if (!isPlainObject(obj)) return prefix ? [prefix] : []
  return Object.keys(obj).flatMap(key => {
    const next = prefix ? `${prefix}.${key}` : key
    return isPlainObject(obj[key]) ? collectKeyPaths(obj[key], next) : [next]
  })
}

const stripPath = (obj, keyPath) => {
  const [head, ...rest] = keyPath.split('.')
  if (!(head in obj)) return { obj, stripped: false }
  if (rest.length === 0) {
    const { [head]: _, ...out } = obj
    return { obj: out, stripped: true }
  }
  if (!isPlainObject(obj[head])) return { obj, stripped: false }
  const { obj: nested, stripped } = stripPath(obj[head], rest.join('.'))
  return { obj: { ...obj, [head]: nested }, stripped }
}

const stripEnforcedKeys = (overrides, enforced) => {
  const paths = collectKeyPaths(enforced)
  let current = overrides
  const stripped = []
  for (const p of paths) {
    const result = stripPath(current, p)
    current = result.obj
    if (result.stripped) stripped.push(p)
  }
  return { overrides: current, stripped }
}

const readYaml = (file, core) => {
  if (!fs.existsSync(file)) {
    core.info(`File not found: ${file} (treating as empty)`)
    return {}
  }
  const raw = fs.readFileSync(file, 'utf8')
  const parsed = yaml.load(raw)
  return isPlainObject(parsed) ? parsed : {}
}

const buildBlueprint = ({ enforced, defaults, overrides, repoName, owner }) => {
  const base = deepMerge(defaults, overrides)
  const merged = deepMerge(base, enforced)
  return { repo: { owner, name: repoName, ...merged } }
}

module.exports = async ({ context, core, inputs }) => {
  const { enforced: enforcedPath, defaults: defaultsPath, repoSettings, buildDir } = inputs
  const { owner, repo: repoName } = context.repo

  const enforced = readYaml(enforcedPath, core)
  const defaults = readYaml(defaultsPath, core)
  const rawOverrides = readYaml(repoSettings, core)

  const { overrides, stripped } = stripEnforcedKeys(rawOverrides, enforced)
  if (stripped.length) {
    core.warning(`Stripped enforced keys from overrides: ${stripped.join(', ')}`)
  }

  const blueprint = buildBlueprint({ enforced, defaults, overrides, repoName, owner })

  fs.mkdirSync(buildDir, { recursive: true })
  const outPath = path.join(buildDir, 'blueprint.auto.tfvars.json')
  fs.writeFileSync(outPath, JSON.stringify(blueprint, null, 2))

  core.info(`Wrote blueprint to ${outPath}`)
  core.setOutput('blueprint-path', outPath)
  core.setOutput('stripped-keys', JSON.stringify(stripped))
}

module.exports._internals = {
  deepMerge,
  collectKeyPaths,
  stripPath,
  stripEnforcedKeys,
  buildBlueprint,
  isPlainObject,
}
