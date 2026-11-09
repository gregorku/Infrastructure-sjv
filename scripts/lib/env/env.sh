#!/usr/bin/env bash
# Loads the whole environment library. Requires config.sh, logging.sh and
# common.sh to be sourced first.

ENV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_LIB_DIR

# shellcheck source=scripts/lib/env/policy.sh
source "${ENV_LIB_DIR}/policy.sh"
# shellcheck source=scripts/lib/env/parse.sh
source "${ENV_LIB_DIR}/parse.sh"
# shellcheck source=scripts/lib/env/net.sh
source "${ENV_LIB_DIR}/net.sh"
# shellcheck source=scripts/lib/env/validate.sh
source "${ENV_LIB_DIR}/validate.sh"
# shellcheck source=scripts/lib/env/sync.sh
source "${ENV_LIB_DIR}/sync.sh"
# shellcheck source=scripts/lib/env/load.sh
source "${ENV_LIB_DIR}/load.sh"
