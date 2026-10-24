resolve_backend_root() {
  local backend_root="${DEPLOYDASH_ORCHESTRATOR_ROOT:-${REPO_ROOT}/orchestrator}"

  if [[ "${backend_root}" != /* ]]; then
    backend_root="${REPO_ROOT}/${backend_root}"
  fi

  if [[ ! -d "${backend_root}" ]]; then
    echo "Orchestrator root not found: ${backend_root}" >&2
    return 1
  fi

  printf '%s\n' "${backend_root}"
}

resolve_backend_script_path() {
  local script_name="$1"
  local backend_root
  backend_root="$(resolve_backend_root)"
  local script_path="${backend_root}/scripts/${script_name}"

  if [[ ! -f "${script_path}" ]]; then
    echo "Backend helper script not found: ${script_path}" >&2
    return 1
  fi

  printf '%s\n' "${script_path}"
}
