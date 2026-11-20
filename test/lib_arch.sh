# Sourced by the docker-based tests. Picks the TARGETARCH build arg for the
# machine running them (Dockerfile has no default and fails fast), so the
# built image can actually run here. Override by exporting TARGETARCH.
case "$(uname -m)" in
  x86_64|amd64) _arch=amd64 ;;
  aarch64|arm64) _arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
TARGETARCH="${TARGETARCH:-$_arch}"
