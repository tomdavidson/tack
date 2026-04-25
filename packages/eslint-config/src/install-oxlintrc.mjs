#!/usr/bin/env node
/**
 * Ensures the root oxlintrc.json has the correct $schema and extends fields
 * pointing to the bundled config. Safe to run repeatedly.
 *
 * - If no file exists, creates a minimal one.
 * - If a file exists, patches $schema and extends without touching other fields.
 * - If extends already contains the bundled path, leaves it alone.
 *
 * Usage:
 *   node node_modules/@astro-bay/eslint-config/src/ensure-oxlintrc.mjs
 *   # or from package.json scripts:
 *   "postinstall": "node node_modules/@astro-bay/eslint-config/src/ensure-oxlintrc.mjs"
 */

import { applyEdits, modify, parse } from 'jsonc-parser'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { relative, resolve } from 'node:path'

const SCHEMA = './node_modules/oxlint/configuration_schema.json'
const EXTENDS_ENTRY = './node_modules/@astro-bay/eslint-config/src/oxlintrc.jsonc'

const findRoot = () => {
  // Walk up from cwd looking for a package.json with workspaces or no parent package.json
  let dir = process.cwd()
  while (dir !== resolve(dir, '..')) {
    if (existsSync(resolve(dir, 'pnpm-workspace.yaml')) || existsSync(resolve(dir, 'pnpm-lock.yaml'))) {
      return dir
    }
    dir = resolve(dir, '..')
  }
  return process.cwd()
}

const root = findRoot()
const target = resolve(root, 'oxlintrc.json')
const targetRelative = relative(root, target).replaceAll('\\', '/') || 'oxlintrc.json'

let text
let config

if (existsSync(target)) {
  text = readFileSync(target, 'utf8')
  try {
    config = parse(text, [], { allowTrailingComma: true, disallowComments: false })

    if (config == null || Array.isArray(config) || typeof config !== 'object') {
      throw new TypeError('Expected oxlintrc.json to contain a JSON object')
    }
  } catch (error) {
    console.error(`[ensure-oxlintrc] Failed to parse ${target}. Skipping.`)
    console.error(error)
    process.exit(0)
  }
} else {
  text = '{}'
  config = {}
}

// Compute updated extends array without mutating config directly
let nextExtends = Array.isArray(config.extends) ? [...config.extends] : []
if (!nextExtends.includes(EXTENDS_ENTRY)) {
  nextExtends = [EXTENDS_ENTRY, ...nextExtends]
}

// Ensure a missing $schema is inserted at the top of the root object so comments are preserved
// and the property order stays friendly for editors.
let textWithSchema = text
if (!Object.hasOwn(config, '$schema')) {
  const objectStart = textWithSchema.indexOf('{')
  if (objectStart === -1) {
    throw new TypeError('Expected oxlintrc.json to contain a root object')
  }

  const insertion = `
  "$schema": ${JSON.stringify(SCHEMA)},`
  textWithSchema = `${textWithSchema.slice(0, objectStart + 1)}${insertion}${
    textWithSchema.slice(objectStart + 1)
  }`
}

// Use jsonc-parser.modify to apply minimal edits sequentially so comments are preserved
const formattingOptions = { insertSpaces: true, tabSize: 2 }

const schemaEdits = modify(textWithSchema, ['$schema'], SCHEMA, { formattingOptions })
textWithSchema = applyEdits(textWithSchema, schemaEdits)

const extendsEdits = modify(textWithSchema, ['extends'], nextExtends, { formattingOptions })
const updatedText = applyEdits(textWithSchema, extendsEdits)

writeFileSync(target, updatedText, 'utf8')
console.log(`[ensure-oxlintrc] ${existsSync(target) ? 'Updated' : 'Created'} ${target}`)
console.log(`[ensure-oxlintrc] Relative path: ${targetRelative}`)
console.log(`[ensure-oxlintrc] Ensured $schema: ${SCHEMA}`)
console.log(`[ensure-oxlintrc] Ensured extends entry: ${EXTENDS_ENTRY}`)
console.log('[ensure-oxlintrc] If your install layout differs, update those paths manually.')
