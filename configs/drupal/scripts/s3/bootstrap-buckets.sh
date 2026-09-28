#!/usr/bin/env bash
#
# Create the S3 buckets and make the files bucket world-readable, using nothing
# but curl's SigV4 signing. Works against any S3-compatible endpoint (RustFS in
# devenv and CI, Tigris/Fly Storage in production). Idempotent.
#
# Env (required): S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY
# Env (optional): S3_BUCKET (drupal-files), BACKUP_BUCKET (skipped when unset),
#                 S3_REGION (auto)

set -euo pipefail
# shellcheck source=scripts/lib/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/env.sh"

env_shim
env_require S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY

readonly FILES_BUCKET="${S3_BUCKET:-drupal-files}"
readonly BACKUP_BUCKET="${BACKUP_BUCKET:-}"
readonly S3_REGION="${S3_REGION:-auto}"
readonly ENDPOINT="${S3_ENDPOINT%/}"

s3_request() {
  curl -fsS --aws-sigv4 "aws:amz:${S3_REGION}:s3" --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" "$@"
}

endpoint_is_healthy() { curl -fsS -o /dev/null "${ENDPOINT}/health"; }
bucket_exists()       { s3_request -o /dev/null -I "${ENDPOINT}/${1}"; }

# PUT on an existing bucket returns 200 on RustFS and 409 BucketAlreadyOwnedByYou
# on others; either way a following HEAD proves the bucket is there.
put_or_find_bucket() {
  s3_request -o /dev/null -X PUT "${ENDPOINT}/${1}" 2>/dev/null || bucket_exists "$1"
}

# RustFS answers /health before its object layer is up; retry on bucket calls.
create_bucket() {
  wait_for "Bucket $1" 60 put_or_find_bucket "$1"
}

public_read_policy() {
  printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::%s/*"]}]}' "$1"
}

allow_anonymous_read() {
  local bucket="$1"
  public_read_policy "${bucket}" \
    | s3_request -o /dev/null -X PUT -H "Content-Type: application/json" --data-binary @- "${ENDPOINT}/${bucket}?policy"
  log "Anonymous read enabled on ${bucket}."
}

main() {
  wait_for "S3 endpoint ${ENDPOINT}" 60 endpoint_is_healthy
  create_bucket "${FILES_BUCKET}"
  allow_anonymous_read "${FILES_BUCKET}"
  if [[ -n "${BACKUP_BUCKET}" ]]; then
    create_bucket "${BACKUP_BUCKET}"
  else
    log "BACKUP_BUCKET unset; no backup bucket created."
  fi
}

main "$@"
