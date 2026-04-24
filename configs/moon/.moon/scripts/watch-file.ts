#!/usr/bin/env bun
// .moon/scripts/watch-file.ts
//
// Dev-loop feedback: typecheck + oxlint + eslint on specific files,
// filtered output, with optional built-in file watching.
//
// Usage:
//   moon run ~:wf -- 'src/*.domain.ts'
//   moon run ~:wf -- src/pricing.domain.ts src/config.ts --fix
//   moon run ~:wf -- 'src/**/*.domain.ts' --watch
//   moon run ~:wf -- 'src/**/*.domain.ts' --fix --watch

import { spawn } from 'bun'
import { Glob } from 'bun'
import { watch } from 'fs'
import { dirname, resolve } from 'path'

const args = process.argv.slice(2)

const fix = args.includes('--fix')
const watchMode = args.includes('--watch') || args.includes('-w')
const patterns = args.filter(a => a !== '--fix' && a !== '--watch' && a !== '-w')

if (patterns.length === 0) {
  console.error('Usage: moon run ~:wf -- <file-or-glob> [--fix] [--watch]')
  process.exit(1)
}

const files = [...new Set(patterns.flatMap(p => [...new Glob(p).scanSync({ cwd: '.', absolute: false })]))]

if (files.length === 0) {
  console.error(`No files matched: ${patterns.join(' ')}`)
  process.exit(1)
}

const resolvedFiles = new Set(files.map(f => resolve(f)))

const RESET = '\x1b[0m'
const BOLD = '\x1b[1m'
const DIM = '\x1b[2m'
const CYAN = '\x1b[36m'
const GREEN = '\x1b[32m'

const timestamp = (): string => new Date().toLocaleTimeString('en-US', { hour12: false })

const stripAnsi = (s: string): string => s.replace(/\x1b\[[0-9;]*m/g, '')

const moonRun = async (
  task: string,
  extraArgs: string[] = [],
): Promise<{ output: string; exitCode: number; timing: string }> => {
  const cmd = ['moon', 'run', task]
  if (extraArgs.length > 0) cmd.push('--', ...extraArgs)

  const proc = spawn({ cmd, stdout: 'pipe', stderr: 'pipe' })
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ])
  const exitCode = await proc.exited
  const raw = stripAnsi(stdout + '\n' + stderr)

  const taskEnd = raw.split('\n').find(l => /^\S+:\S+\s+\(\d/.test(l))
  const timeLine = raw.split('\n').find(l => l.includes('Time:'))
  const timing = taskEnd?.match(/\((\d\S+)/)?.[1] ?? timeLine?.match(/Time:\s*(\S+)/)?.[1] ?? ''

  return { output: raw.trim(), exitCode, timing }
}

const stripMoonChrome = (output: string): string =>
  output.split('\n').map(line => line.match(/^\S+:\S+\s+\|\s+(.*)/)?.[1] ?? line).filter(line =>
    !line.includes('to the moon') &&
    !line.includes('Tasks:') &&
    !line.includes('Time:') &&
    !line.includes('cached') &&
    !line.includes('Finished in') &&
    !line.includes('Found 0 warnings and 0 errors') &&
    !/\([a-f0-9]{8}\)/.test(line)
  ).join('\n').trim()

const filterToFiles = (output: string): string => {
  const cleaned = stripMoonChrome(output)
  const filePatterns = files.flatMap(f => [f, resolve(f)])
  const blocks = cleaned.split(/\n(?=\S)/)

  return blocks.filter(block => filePatterns.some(p => block.includes(p))).join('\n').trim()
}

const runTypecheck = async (): Promise<string> => {
  const { output, exitCode, timing } = await moonRun('~:check-types')
  const filtered = filterToFiles(output)
  const header = `${CYAN}--- check-types ---${RESET}`
  return `${header}\n${
    !filtered && exitCode === 0 ? `${GREEN}✓${RESET}${DIM} | ${timing}${RESET}` : filtered || output
  }`
}

const runEslint = async (): Promise<string> => {
  const extra = fix ? ['--fix', ...files] : files
  const { output, timing } = await moonRun('~:lint-es', extra)
  const cleaned = stripMoonChrome(output)
  const header = `${CYAN}--- eslint${fix ? ' --fix' : ''} ---${RESET}`
  return `${header}\n${cleaned || `${GREEN}✓${RESET}${DIM} | ${timing}${RESET}`}`
}

const runOxlint = async (): Promise<string> => {
  const extra = fix ? ['--fix', ...files] : files
  const { output, timing } = await moonRun('~:lint-ox', extra)
  const cleaned = stripMoonChrome(output)
  const header = `${CYAN}--- oxlint${fix ? ' --fix' : ''} ---${RESET}`
  return `${header}\n${
    !cleaned || /^Found 0 warnings and 0 errors/.test(cleaned) ?
      `${GREEN}✓${RESET}${DIM} | ${timing}${RESET}` :
      cleaned.replace(/^Finished in .+$/m, '').trim()
  }`
}

let running = false
let pendingRerun = false

const runLintsSequential = async (): Promise<string[]> => {
  const es = await runEslint()
  const ox = await runOxlint()
  return [es, ox]
}

const runLintsParallel = (): Promise<string[]> => Promise.all([runEslint(), runOxlint()])

const runLints = fix ? runLintsSequential : runLintsParallel

const cycle = async (): Promise<void> => {
  if (running) {
    pendingRerun = true
    return
  }
  running = true

  const mode = fix ? 'fix' : 'check'
  console.log(`\n${BOLD}=== ${timestamp()} [${mode}] ${files.length} file(s) ===${RESET}`)

  const [typeResult, lintResults] = await Promise.all([runTypecheck(), runLints()])
  console.log([typeResult, ...lintResults].join('\n\n'))
  console.log(`\n${DIM}=== done ===${RESET}\n\n`)

  running = false
  if (pendingRerun) {
    pendingRerun = false
    void cycle()
  }
}

console.log(`${BOLD}mode:${RESET} ${fix ? 'fix' : 'check'}`)
console.log(`${BOLD}files:${RESET} ${files.join(', ')}`)

if (watchMode) console.log(`${BOLD}watching for changes...${RESET}`)

await cycle()

if (watchMode) {
  const dirs = new Set<string>()
  for (const f of files) {
    dirs.add(dirname(resolve(f)))
  }

  let debounceTimer: ReturnType<typeof setTimeout> | null = null

  for (const dir of dirs) {
    watch(dir, (_event, filename) => {
      if (!filename) return

      const full = resolve(dir, filename)
      if (!resolvedFiles.has(full)) return

      if (debounceTimer) clearTimeout(debounceTimer)
      debounceTimer = setTimeout(() => {
        debounceTimer = null
        void cycle()
      }, 300)
    })
  }

  process.on('SIGINT', () => {
    console.log(`\n${DIM}stopped${RESET}`)
    process.exit(0)
  })
}
