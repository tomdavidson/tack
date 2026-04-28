// .github/actions/gh-settings/comment.js
//
// Posts (or updates) a single PR comment with the OpenTofu plan output and any
// stripped enforced keys. The comment is identified by an HTML marker so repeat
// runs on the same PR update in place rather than spamming new comments.

const MARKER = '<!-- gh-settings-plan -->'

const buildBody = ({ planSummary, strippedKeys, changed }) => {
  const stripped = JSON.parse(strippedKeys || '[]')
  const changeHeader = changed === 'true' ?
    '### 🟡 GitHub Settings Plan: changes pending' :
    '### 🟢 GitHub Settings Plan: no changes'

  const strippedBlock = stripped.length ?
    ['', '**Stripped enforced keys** (ignored from repo overrides):', '', ...stripped.map(k => `- \`${k}\``)]
      .join('\n') :
    ''

  const plan = planSummary?.trim() || '(no plan output captured)'

  return [
    MARKER,
    changeHeader,
    strippedBlock,
    '',
    '<details><summary>Plan output</summary>',
    '',
    '```',
    plan,
    '```',
    '',
    '</details>',
  ].join('\n')
}

const findExisting = async (github, owner, repo, issueNumber) => {
  const { data } = await github.rest.issues.listComments({
    owner,
    repo,
    issue_number: issueNumber,
    per_page: 100,
  })
  return data.find(c => c.body?.startsWith(MARKER))
}

module.exports = async ({ github, context, core, inputs }) => {
  const { owner, repo } = context.repo
  const issueNumber = context.payload.pull_request?.number
  if (!issueNumber) {
    core.info('Not a pull request, skipping comment')
    return
  }

  const body = buildBody(inputs)
  const existing = await findExisting(github, owner, repo, issueNumber)

  if (existing) {
    await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id, body })
    core.info(`Updated PR comment ${existing.id}`)
    return
  }

  await github.rest.issues.createComment({ owner, repo, issue_number: issueNumber, body })
  core.info('Created PR comment')
}

module.exports._internals = { buildBody, MARKER }
