import socket
import ssl
from collections.abc import Callable


BLABLADOR_HOST = "api.blablador.fz-juelich.de"


class _UnexpectedAllowed(RuntimeError):
    pass


def resolve(host: str) -> tuple[str, ...]:
    addresses = {
        result[4][0]
        for result in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    }
    if not addresses:
        raise socket.gaierror()
    return tuple(sorted(addresses))


def verified_tls(
    connect_host: str, server_hostname: str, timeout_seconds: float = 5.0
) -> None:
    context = ssl.create_default_context()
    with socket.create_connection((connect_host, 443), timeout=timeout_seconds) as raw:
        with context.wrap_socket(raw, server_hostname=server_hostname):
            pass


def _tls_handshake_without_certificate_validation(
    connect_host: str, server_hostname: str, timeout_seconds: float = 5.0
) -> None:
    # A negative SNI probe must not confuse a normal hostname mismatch with
    # enforcement by Cilium. It sends no request or credential.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with socket.create_connection((connect_host, 443), timeout=timeout_seconds) as raw:
        with context.wrap_socket(raw, server_hostname=server_hostname):
            pass


def require_blocked(name: str, action: Callable[[], None]) -> None:
    try:
        action()
    except OSError:
        print(f"{name}: PASS")
        return
    print(f"{name}: FAIL")
    raise _UnexpectedAllowed(name)


def _blocked(name: str, action: Callable[[], None]) -> bool:
    try:
        require_blocked(name, action)
    except _UnexpectedAllowed:
        return False
    except Exception:
        print(f"{name}: FAIL")
        return False
    return True


def main() -> int:
    try:
        verified_tls(BLABLADOR_HOST, BLABLADOR_HOST)
    except Exception:
        print("blablador-tls: FAIL")
        return 1
    print("blablador-tls: PASS")

    if not _blocked("unrelated-dns", lambda: resolve("example.com")):
        return 1
    if not _blocked(
        "public-tls", lambda: verified_tls("1.1.1.1", "one.one.one.one")
    ):
        return 1
    if not _blocked(
        "private-ip", lambda: verified_tls("10.255.255.1", "10.255.255.1")
    ):
        return 1
    if not _blocked(
        "metadata-ip",
        lambda: verified_tls("169.254.169.254", "169.254.169.254"),
    ):
        return 1

    try:
        provider_ip = resolve(BLABLADOR_HOST)[0]
    except Exception:
        print("wrong-sni: FAIL")
        return 1
    if not _blocked(
        "wrong-sni",
        lambda: _tls_handshake_without_certificate_validation(
            provider_ip, "example.com"
        ),
    ):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
