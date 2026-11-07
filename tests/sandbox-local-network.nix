# SPDX-License-Identifier: MIT
# A sandboxed socket boundary test for checks that run local HTTP servers.
{ pkgs }:
pkgs.runCommand "sandbox-local-network-boundary"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    __darwinAllowLocalNetworking = pkgs.stdenv.hostPlatform.isDarwin;
  }
  ''
    python - <<'PY'
    import errno, json, os, socket, sys
    with socket.socket() as server, socket.socket() as client:
        server.settimeout(5)
        client.settimeout(5)
        server.bind(('127.0.0.1', 0))
        server.listen(1)
        client.connect(server.getsockname())
        connection, _ = server.accept()
        with connection:
            connection.settimeout(5)
            client.sendall(b'tcp-request')
            assert connection.recv(64) == b'tcp-request'
            connection.sendall(b'tcp-response')
            assert client.recv(64) == b'tcp-response'
    with socket.socket(type=socket.SOCK_DGRAM) as server, socket.socket(type=socket.SOCK_DGRAM) as client:
        server.settimeout(5)
        client.settimeout(5)
        server.bind(('127.0.0.1', 0))
        client.sendto(b'udp-request', server.getsockname())
        request, address = server.recvfrom(64)
        assert request == b'udp-request'
        server.sendto(b'udp-response', address)
        assert client.recvfrom(64)[0] == b'udp-response'
    assert sys.platform in ('darwin', 'linux'), sys.platform
    permission_denied = (errno.EPERM, errno.EACCES)
    allowed_errors = permission_denied if sys.platform == 'darwin' else permission_denied + (errno.ENETUNREACH, errno.EHOSTUNREACH)
    denied = {}
    for kind, name in [(socket.SOCK_STREAM, 'tcp'), (socket.SOCK_DGRAM, 'udp')]:
        with socket.socket(type=kind) as external:
            external.settimeout(3)
            try:
                if kind == socket.SOCK_STREAM:
                    external.connect(('192.0.2.1', 9))
                else:
                    external.sendto(b'forbidden', ('192.0.2.1', 9))
            except OSError as error:
                assert error.errno in allowed_errors, error
                denied[name] = error.errno
            else:
                raise AssertionError(f'external {name} unexpectedly allowed')
    with open(os.environ['out'], 'w') as receipt:
        json.dump({'platform': sys.platform, 'loopbackTcp': True, 'loopbackUdp': True, 'externalTestNetDenied': denied, 'denialMechanism': 'seatbelt-permission' if sys.platform == 'darwin' else 'linux-network-namespace'}, receipt)
    PY
  ''
