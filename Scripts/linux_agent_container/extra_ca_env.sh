# shellcheck shell=bash
# Source with two arguments: an optional PEM file of additional trusted CA
# certificates (for example a TLS-inspecting corporate proxy root) and a
# directory for the combined bundle. When the PEM file exists, write the system
# roots plus that file to a bundle in the directory and point common TLS clients
# at it.
#
# The directory must not be persisted: image builds pass a per-step tmpfs mount
# (never part of a layer or the build cache); containers pass the /tmp tmpfs.
rpce_extra_ca="${1:-}"
rpce_ca_dir="${2:-}"
if [[ -n "$rpce_extra_ca" && -s "$rpce_extra_ca" ]]; then
  if [[ -z "$rpce_ca_dir" || ! -d "$rpce_ca_dir" ]]; then
    printf 'extra_ca_env: bundle directory %s does not exist\n' "${rpce_ca_dir:-<unset>}" >&2
    return 1
  fi
  rpce_ca_bundle="$(mktemp "$rpce_ca_dir/rpce-ca-bundle.XXXXXX")"
  cat /etc/ssl/certs/ca-certificates.crt "$rpce_extra_ca" >"$rpce_ca_bundle"
  chmod 0644 "$rpce_ca_bundle"
  export SSL_CERT_FILE="$rpce_ca_bundle" CURL_CA_BUNDLE="$rpce_ca_bundle" \
    GIT_SSL_CAINFO="$rpce_ca_bundle" REQUESTS_CA_BUNDLE="$rpce_ca_bundle" \
    NODE_EXTRA_CA_CERTS="$rpce_extra_ca"
fi
unset rpce_extra_ca rpce_ca_dir rpce_ca_bundle
