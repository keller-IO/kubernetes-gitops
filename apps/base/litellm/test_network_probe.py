import io
import socket
import ssl
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import MagicMock, call, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import network_probe


class NetworkProbeTests(unittest.TestCase):
    @patch("network_probe.ssl.create_default_context")
    @patch("network_probe.socket.create_connection")
    def test_verified_tls_uses_default_context_and_expected_sni(
        self, create_connection, create_default_context
    ):
        connection = MagicMock()
        create_connection.return_value.__enter__.return_value = connection
        tls_socket = MagicMock()
        context = create_default_context.return_value
        context.wrap_socket.return_value.__enter__.return_value = tls_socket

        network_probe.verified_tls(
            "203.0.113.10", "api.blablador.fz-juelich.de", 3.0
        )

        create_default_context.assert_called_once_with()
        create_connection.assert_called_once_with(("203.0.113.10", 443), timeout=3.0)
        context.wrap_socket.assert_called_once_with(
            connection, server_hostname="api.blablador.fz-juelich.de"
        )

    def test_require_blocked_fails_when_operation_returns(self):
        output = io.StringIO()

        with redirect_stdout(output), self.assertRaises(RuntimeError):
            network_probe.require_blocked("unexpected-route", lambda: None)

        self.assertEqual(output.getvalue(), "unexpected-route: FAIL\n")

    def test_require_blocked_accepts_network_timeout_and_tls_errors(self):
        cases = (
            ("network-timeout", socket.timeout()),
            ("tls-error", ssl.SSLError()),
        )

        for name, error in cases:
            with self.subTest(name=name):
                output = io.StringIO()

                def blocked():
                    raise error

                with redirect_stdout(output):
                    network_probe.require_blocked(name, blocked)

                self.assertEqual(output.getvalue(), f"{name}: PASS\n")

    @patch("network_probe._tls_handshake_without_certificate_validation")
    @patch("network_probe.verified_tls")
    @patch("network_probe.resolve")
    def test_main_runs_allowed_and_all_blocked_cases_without_values(
        self, resolve, verified_tls, wrong_sni_handshake
    ):
        resolved_provider_ip = "203.0.113.10"

        def resolve_side_effect(host):
            if host == network_probe.BLABLADOR_HOST:
                return (resolved_provider_ip,)
            if host == "example.com":
                raise socket.gaierror()
            self.fail(f"unexpected host requested: {host}")

        def tls_side_effect(connect_host, server_hostname, timeout_seconds=5.0):
            if (connect_host, server_hostname) == (
                network_probe.BLABLADOR_HOST,
                network_probe.BLABLADOR_HOST,
            ):
                return None
            if connect_host in {"10.255.255.1", "169.254.169.254"}:
                raise socket.timeout()
            if (connect_host, server_hostname) == ("1.1.1.1", "one.one.one.one"):
                raise socket.timeout()
            self.fail(f"unexpected TLS case: {connect_host}, {server_hostname}")

        resolve.side_effect = resolve_side_effect
        verified_tls.side_effect = tls_side_effect
        wrong_sni_handshake.side_effect = ssl.SSLError()
        output = io.StringIO()

        with redirect_stdout(output):
            result = network_probe.main()

        self.assertEqual(result, 0)
        self.assertEqual(
            output.getvalue().splitlines(),
            [
                "blablador-tls: PASS",
                "unrelated-dns: PASS",
                "public-tls: PASS",
                "private-ip: PASS",
                "metadata-ip: PASS",
                "wrong-sni: PASS",
            ],
        )
        self.assertNotIn(resolved_provider_ip, output.getvalue())
        self.assertEqual(
            verified_tls.call_args_list,
            [
                call(
                    network_probe.BLABLADOR_HOST,
                    network_probe.BLABLADOR_HOST,
                ),
                call("1.1.1.1", "one.one.one.one"),
                call("10.255.255.1", "10.255.255.1"),
                call("169.254.169.254", "169.254.169.254"),
            ],
        )
        wrong_sni_handshake.assert_called_once_with(resolved_provider_ip, "example.com")


if __name__ == "__main__":
    unittest.main()
