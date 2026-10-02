#!/usr/bin/env bash
# Receives only validated release/image identifiers, never sources the .env file.
set -Eeuo pipefail
release="${1:?release required}"
image_name="${2:?image name required}"
image_tag="${3:?image tag required}"
[[ "$release" =~ ^[a-f0-9]{40}-[0-9]+-[0-9]+$ ]]
[[ "$image_name" =~ ^ghcr.io/[a-z0-9._/-]+$ ]]
[[ "$image_tag" =~ ^cpu-[a-f0-9]{40}$ ]]

deploy_root="$HOME/vieneu-tts"
cd "$deploy_root"
# Also protects against overlapping manual deployments.
exec 9>"$deploy_root/deploy.lock"
flock -w 1800 9
env_file="$deploy_root/releases/$release/.env"
test -s "$env_file" || { echo 'Missing release .env; configure GitHub Variable ENV_FILE'; exit 1; }
chmod 600 "$env_file"
compose_file="$deploy_root/releases/$release/compose.yml"
export IMAGE_NAME="$image_name" IMAGE_TAG="$image_tag"
compose=(docker compose -p vieneu-tts --env-file "$env_file" -f "$compose_file")
"${compose[@]}" config --quiet
services=$("${compose[@]}" config --services)
[[ -n "$services" ]] || { echo 'Set COMPOSE_PROFILES=web, api, or web,api in .env'; exit 1; }
# Download first: a failed pull leaves the current containers untouched.
"${compose[@]}" pull
if ! "${compose[@]}" up -d --remove-orphans --wait --wait-timeout 900; then
    "${compose[@]}" ps
    "${compose[@]}" logs --tail 80 || true
    if [[ -f last-success ]]; then
        mapfile -t previous < last-success
        export IMAGE_NAME="${previous[1]}" IMAGE_TAG="${previous[2]}"
        previous_env="$deploy_root/releases/${previous[0]}/.env"
        # Compatibility with releases deployed before ENV_FILE support.
        [[ -f "$previous_env" ]] || previous_env="$deploy_root/.env"
        echo "Restoring previous release: ${previous[0]}"
        docker compose -p vieneu-tts --env-file "$previous_env" \
            -f "$deploy_root/releases/${previous[0]}/compose.yml" \
            up -d --remove-orphans --wait --wait-timeout 900
    else
        echo 'First deployment failed; there is no previous release to restore.'
    fi
    exit 1
fi
printf '%s\n' "$release" "$image_name" "$image_tag" > last-success.tmp
mv last-success.tmp last-success
ln -sfn "releases/$release/compose.yml" compose.yml
ln -sfn "releases/$release/.env" .env
echo "Healthy release: $image_name:$image_tag"
