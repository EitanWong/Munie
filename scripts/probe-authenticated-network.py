#!/usr/bin/env python3
"""Exercise temporary loopback mTLS + synthetic authorization, never a product gateway."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, HTTPServer
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

SPEC = importlib.util.spec_from_file_location('report_helper', Path(__file__).with_name('probe-codex.py'))
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
MAX_BODY = 2048
MAX_RESPONSE = 2048
MAX_ACCEPTED = 4
IO_SECONDS = 3
PROJECT = 'synthetic-project'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON member')
        result[key] = value
    return result


class FixtureAuthorization:
    """In-memory test policy only: no pairing, durable ledger, Codex or user projects."""

    def __init__(self, devices):
        self.devices = devices
        self.revoked = set()
        self.accepted = {}
        self.connections = 0

    def submit(self, fingerprint, body):
        device = self.devices.get(fingerprint)
        if device is None or fingerprint in self.revoked:
            return 403, {'error': 'device-denied'}
        try:
            value = json.loads(body.decode('utf-8'), object_pairs_hook=unique_object)
            require(type(value) is dict and set(value) == {'requestID', 'projectID', 'payload'},
                    'Unexpected fixture schema')
            require(all(type(item) is str and 0 < len(item.encode('utf-8')) <= 256
                        for item in value.values()), 'Invalid fixture strings')
        except (ValueError, UnicodeError):
            return 400, {'error': 'invalid-request'}
        if value['projectID'] != PROJECT:
            return 403, {'error': 'project-denied'}
        identity = (device, value['projectID'], value['payload'])
        previous = self.accepted.get(value['requestID'])
        if previous is not None:
            if previous[0] != identity:
                return 409, {'error': 'request-conflict'}
            return 200, {'state': 'fixture-accepted', 'ordinal': previous[1]}
        if len(self.accepted) >= MAX_ACCEPTED:
            return 429, {'error': 'fixture-capacity'}
        ordinal = len(self.accepted) + 1
        self.accepted[value['requestID']] = (identity, ordinal)
        return 202, {'state': 'fixture-accepted', 'ordinal': ordinal}


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass  # No certificate, request path, content or header logging.

    def send_result(self, status, value, close=False):
        wire = json.dumps(value, separators=(',', ':')).encode('utf-8')
        require(len(wire) <= MAX_RESPONSE, 'Fixture response limit')
        self.close_connection = close
        self.send_response_only(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(wire)))
        self.send_header('Cache-Control', 'no-store')
        if close:
            self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(wire)
        self.wfile.flush()

    def do_POST(self):
        if self.path != '/fixture/submit':
            self.send_result(404, {'error': 'fixture-route'}, close=True)
            return
        lengths = self.headers.get_all('Content-Length', [])
        if (len(lengths) != 1 or not lengths[0].isascii() or not lengths[0].isdigit() or
                len(lengths[0]) > 6 or self.headers.get('Transfer-Encoding') is not None or
                self.headers.get('Content-Type') != 'application/json'):
            self.send_result(400, {'error': 'fixture-framing'}, close=True)
            return
        length = int(lengths[0])
        if not 0 < length <= MAX_BODY:
            self.send_result(413, {'error': 'fixture-body-limit'}, close=True)
            return
        # A total body deadline, including dribbled input, rather than only per-read inactivity.
        deadline = time.monotonic() + IO_SECONDS
        body = bytearray()
        while len(body) < length:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self.close_connection = True
                return
            self.connection.settimeout(remaining)
            part = self.rfile.read1(length - len(body))
            if not part:
                self.close_connection = True
                return
            body.extend(part)
        self.connection.settimeout(IO_SECONDS)
        fingerprint = hashlib.sha256(self.connection.getpeercert(binary_form=True)).hexdigest()
        # Read the live deny policy for EVERY request, even on a pre-existing TLS connection.
        status, result = self.server.policy.submit(fingerprint, bytes(body))
        self.send_result(status, result, close=status == 403)


class FixtureServer(HTTPServer):
    """One bounded worker, loopback only; http.server is unsuitable for production."""

    def __init__(self, context, policy, handler=FixtureHandler):
        self.context, self.policy = context, policy
        self.active = set()
        self.active_lock = threading.Lock()
        self.stopping = False
        super().__init__(('127.0.0.1', 0), handler)

    def get_request(self):
        raw, address = super().get_request()
        raw.settimeout(IO_SECONDS)
        secured = None
        try:
            with self.active_lock:
                if self.stopping:
                    raise OSError('Fixture is stopping')
                self.active.add(raw)
            # Publish the SSL socket before the potentially blocking handshake, so cleanup
            # can interrupt both a stalled handshake and a dribbled HTTP header.
            secured = self.context.wrap_socket(raw, server_side=True, do_handshake_on_connect=False)
            with self.active_lock:
                self.active.discard(raw)
                if self.stopping:
                    raise OSError('Fixture is stopping')
                self.active.add(secured)
            secured.do_handshake()
        except BaseException:
            self.close_request(secured if secured is not None else raw)
            with self.active_lock:
                self.active.discard(raw)
            raise
        self.policy.connections += 1
        return secured, address

    def close_request(self, request):
        with self.active_lock:
            self.active.discard(request)
        super().close_request(request)

    def stop_connections(self):
        with self.active_lock:
            self.stopping = True
            for connection in self.active:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                connection.close()
            self.active.clear()

    def handle_error(self, *_):
        # Expected bad TLS/body fixtures must not dump content or paths to stderr.
        pass


class LoopbackClient(http.client.HTTPSConnection):
    def __init__(self, port, context, hostname='localhost'):
        super().__init__('localhost', port, context=context, timeout=IO_SECONDS)
        self.hostname = hostname

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def connect(self):
        raw = socket.create_connection(('127.0.0.1', self.port), timeout=IO_SECONDS)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=self.hostname)
        except BaseException:
            raw.close()
            raise

    def submit(self, value=None, body=None, headers=None):
        if body is None:
            body = json.dumps(value, separators=(',', ':')).encode('utf-8')
        self.request('POST', '/fixture/submit', body=body,
                     headers=headers or {'Content-Type': 'application/json'})
        response = self.getresponse()
        wire = response.read(MAX_RESPONSE + 1)
        require(len(wire) <= MAX_RESPONSE, 'Client response limit')
        require(response.getheader('Content-Type') == 'application/json', 'Unexpected content type')
        return response.status, json.loads(wire.decode('utf-8'), object_pairs_hook=unique_object)


def openssl_run(executable, root, *arguments):
    # No inherited config, proxy, key logging or user trust store. No command output is retained.
    result = subprocess.run([str(executable), *arguments], cwd=root,
                            env={'PATH': '/usr/bin:/bin', 'LANG': 'C',
                                 'OPENSSL_CONF': str(root / 'empty.cnf')},
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
    require(result.returncode == 0, 'Fixture certificate generation failed')


def make_certificates(executable, root):
    (root / 'empty.cnf').write_text('', encoding='utf-8')
    for name in ('ca', 'untrusted-ca'):
        config = root / (name + '.cnf')
        config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ca\n'
                          '[dn]\nCN=Munie Synthetic CA\n[ca]\n'
                          'basicConstraints=critical,CA:true,pathlen:0\n'
                          'keyUsage=critical,keyCertSign,cRLSign\n'
                          'subjectKeyIdentifier=hash\n', encoding='utf-8')
        openssl_run(executable, root, 'req', '-x509', '-newkey', 'ec', '-pkeyopt',
                    'ec_paramgen_curve:prime256v1', '-nodes', '-days', '1', '-sha256',
                    '-config', str(config), '-keyout', name + '.key', '-out', name + '.pem')
    for serial, name in enumerate(('server', 'device-a', 'device-b', 'unknown', 'untrusted'), 1):
        ca = 'untrusted-ca' if name == 'untrusted' else 'ca'
        purpose = 'serverAuth' if name == 'server' else 'clientAuth'
        config = root / (name + '.cnf')
        config.write_text('[req]\nprompt=no\ndistinguished_name=dn\n[dn]\n'
                          'CN=Munie Synthetic Peer\n[leaf]\nbasicConstraints=critical,CA:false\n'
                          'keyUsage=critical,digitalSignature\nextendedKeyUsage=' + purpose + '\n'
                          'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n' +
                          ('subjectAltName=DNS:localhost\n' if name == 'server' else ''),
                          encoding='utf-8')
        openssl_run(executable, root, 'req', '-new', '-newkey', 'ec', '-pkeyopt',
                    'ec_paramgen_curve:prime256v1', '-nodes', '-config', str(config),
                    '-keyout', name + '.key', '-out', name + '.csr')
        openssl_run(executable, root, 'x509', '-req', '-in', name + '.csr', '-CA', ca + '.pem',
                    '-CAkey', ca + '.key', '-set_serial', str(serial), '-days', '1', '-sha256',
                    '-extfile', str(config), '-extensions', 'leaf', '-out', name + '.pem')
    for path in root.iterdir():
        path.chmod(0o600)


def tls_context(root, server=False, identity=None, ca='ca'):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER if server else ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.verify_mode = ssl.CERT_REQUIRED
    context.verify_flags |= ssl.VERIFY_X509_STRICT
    context.load_verify_locations(cafile=str(root / (ca + '.pem')))
    context.set_alpn_protocols(['http/1.1'])
    if server:
        identity = 'server'
        context.num_tickets = 0
    if identity is not None:
        context.load_cert_chain(str(root / (identity + '.pem')), str(root / (identity + '.key')))
    require(context.keylog_filename is None, 'Fixture must not log TLS secrets')
    return context


def fingerprint(root, name):
    der = ssl.PEM_cert_to_DER_cert((root / (name + '.pem')).read_text(encoding='ascii'))
    return hashlib.sha256(der).hexdigest()


@contextmanager
def running_server(context, policy, report, handler=FixtureHandler):
    server = FixtureServer(context, policy, handler)
    thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .02})
    thread.start()
    try:
        yield server.server_port
    finally:
        server.stop_connections()
        server.shutdown()
        server.server_close()
        thread.join(timeout=IO_SECONDS + 1)
        report['serverStopped'] = not thread.is_alive() and server.socket.fileno() == -1
        require(report['serverStopped'], 'Fixture server did not stop')


def experiment(executable, report):
    if not ssl.HAS_TLSv1_3:
        report['failureCode'] = 'tls13-unavailable'
    require(ssl.HAS_TLSv1_3, 'Runtime lacks TLS 1.3; select a supported Python explicitly')
    require(executable.is_absolute() and executable.is_file() and os.access(executable, os.X_OK),
            'Select an explicit OpenSSL executable')
    report['runtime'] = {'python': sys.version, 'executable': sys.executable,
                         'ssl': ssl.OPENSSL_VERSION,
                         'openssl': subprocess.check_output([str(executable), 'version'],
                                                            text=True, timeout=5).strip()}
    report['runnerSHA256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    root_repository = Path(__file__).resolve().parent.parent
    report['sourceRevision'] = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=root_repository, text=True).strip()
    report['workingTreeDirty'] = bool(subprocess.check_output(
        ['git', 'status', '--porcelain'], cwd=root_repository, text=True).strip())
    report['scope'] = ('Actual loopback TLS 1.3 and HTTP with temporary certificates; synthetic '
                       'in-memory policy. No Apple client, pairing, ledger, Codex, model, relay or WAN.')
    report['cases'] = []
    temporary_path = None
    try:
        with tempfile.TemporaryDirectory(prefix='munie-mtls-fixture-') as temporary:
            root = Path(temporary).resolve()
            temporary_path = root
            make_certificates(executable, root)
            device_a = fingerprint(root, 'device-a')
            policy = FixtureAuthorization({device_a: 'device-a',
                                           fingerprint(root, 'device-b'): 'device-b'})
            context = tls_context(root, server=True)
            with running_server(context, policy, report) as port:
                contexts = {name: tls_context(root, identity=name)
                            for name in ('device-a', 'device-b', 'unknown', 'untrusted')}
                value = {'requestID': 'synthetic-1', 'projectID': PROJECT, 'payload': 'synthetic-task'}

                def check(name, expected, identity='device-a', request=None, body=None, headers=None):
                    with LoopbackClient(port, contexts[identity]) as client:
                        actual = client.submit(value if request is None else request, body, headers)
                    record = {'name': name, 'httpStatus': actual[0], 'result': actual[1]}
                    report['cases'].append(record)
                    require(actual == expected, 'Unexpected outcome: ' + name)

                for name, client_context, hostname in (
                        ('untrusted-server', tls_context(root, identity='device-a', ca='untrusted-ca'),
                         'localhost'),
                        ('wrong-hostname', contexts['device-a'], 'wrong.invalid'),
                        ('missing-client-certificate', tls_context(root), 'localhost'),
                        ('untrusted-client-certificate', contexts['untrusted'], 'localhost')):
                    try:
                        with LoopbackClient(port, client_context, hostname) as client:
                            client.submit(value)
                    except ssl.SSLError as error:
                        report['cases'].append({'name': name, 'tlsRejected': True,
                                                'failureType': type(error).__name__})
                    else:
                        raise ValueError('TLS accepted: ' + name)
                require(not policy.accepted, 'Untrusted peer reached fixture acceptance')
                check('ca-trusted-unenrolled-device', (403, {'error': 'device-denied'}), identity='unknown')
                check('forged-payload-identity', (400, {'error': 'invalid-request'}),
                      request=dict(value, deviceID='device-b'))
                check('unauthorized-project', (403, {'error': 'project-denied'}),
                      request=dict(value, projectID='other-project'))
                check('first-acceptance', (202, {'state': 'fixture-accepted', 'ordinal': 1}))
                check('same-request-retry', (200, {'state': 'fixture-accepted', 'ordinal': 1}))
                check('conflicting-payload', (409, {'error': 'request-conflict'}),
                      request=dict(value, payload='changed-task'))
                check('cross-device-request-replay', (409, {'error': 'request-conflict'}), identity='device-b')
                check('duplicate-json-member', (400, {'error': 'invalid-request'}),
                      body=b'{"requestID":"synthetic-duplicate","requestID":"forged",'
                           b'"projectID":"synthetic-project","payload":"synthetic-task"}')
                check('oversized-body', (413, {'error': 'fixture-body-limit'}), body=b'x' * (MAX_BODY + 1))
                check('ambiguous-framing', (400, {'error': 'fixture-framing'}), body=b'{}',
                      headers={'Content-Type': 'application/json', 'Transfer-Encoding': 'chunked'})
                # A client that never completes TLS must be disconnected, then release the worker.
                with socket.create_connection(('127.0.0.1', port), timeout=IO_SECONDS + 2) as stalled:
                    require(stalled.recv(1) == b'', 'Silent handshake was not closed')
                report['cases'].append({'name': 'silent-handshake-timeout', 'connectionClosed': True})
                with LoopbackClient(port, contexts['device-a']) as client:
                    client.connect()
                    client.sock.settimeout(IO_SECONDS + 2)
                    client.sock.sendall(b'POST /fixture/submit HTTP/1.1\r\nHost: localhost\r\n'
                                        b'Content-Type: application/json\r\nContent-Length: 10\r\n\r\n{')
                    require(client.sock.recv(1) == b'', 'Incomplete body was not closed')
                report['cases'].append({'name': 'incomplete-body-timeout', 'connectionClosed': True})
                check('worker-recovered-after-timeouts',
                      (200, {'state': 'fixture-accepted', 'ordinal': 1}))
                with LoopbackClient(port, contexts['device-a']) as client:
                    require(client.submit(value) == (200, {'state': 'fixture-accepted', 'ordinal': 1}),
                            'Pre-revocation retry failed')
                    tls_version = client.sock.version()
                    connections = policy.connections
                    # In-process test control, never a remotely callable administrative route.
                    policy.revoked.add(device_a)
                    actual = client.submit(value)
                    report['cases'].append({'name': 'revocation-on-existing-connection',
                                            'httpStatus': actual[0], 'result': actual[1],
                                            'sameTLSConnection': policy.connections == connections,
                                            'tlsVersion': tls_version})
                    require(actual == (403, {'error': 'device-denied'}) and
                            policy.connections == connections and tls_version == 'TLSv1.3',
                            'Revoked existing session retained access')
                check('revocation-on-new-connection', (403, {'error': 'device-denied'}))
                require(len(policy.accepted) == 1, 'Rejected request changed fixture acceptance')
                report['acceptedBeforeCapacityTest'] = len(policy.accepted)
                for index in range(2, MAX_ACCEPTED + 1):
                    check('capacity-fill-' + str(index),
                          (202, {'state': 'fixture-accepted', 'ordinal': index}), identity='device-b',
                          request=dict(value, requestID='synthetic-' + str(index)))
                check('capacity-limit', (429, {'error': 'fixture-capacity'}), identity='device-b',
                      request=dict(value, requestID='synthetic-overflow'))
                report['fixtureAcceptances'] = len(policy.accepted)
            # Cleanup must interrupt an active incomplete header, rather than wait for
            # HTTPServer.shutdown() behind that request. This is a separate listener.
            cleanup = {}
            client = None
            try:
                with running_server(context, policy, cleanup) as port:
                    client = LoopbackClient(port, contexts['device-b'])
                    client.connect()
                    client.sock.sendall(b'POST /fixture/submit HTTP/1.1\r\nHost: local')
                try:
                    require(client.sock.recv(1) == b'', 'Cleanup retained incomplete-header connection')
                    report['pendingHeaderClientClose'] = 'eof'
                except ConnectionResetError:
                    # Closing with unread request bytes may reset TCP instead of sending EOF.
                    report['pendingHeaderClientClose'] = 'reset'
                report['pendingHeaderClosedOnCleanup'] = cleanup.get('serverStopped') is True
            finally:
                if client is not None:
                    client.close()
            require(report['pendingHeaderClosedOnCleanup'], 'Pending-header cleanup failed')
            report['certificateFilesPrivate'] = all(path.stat().st_mode & 0o777 == 0o600
                                                    for path in root.iterdir())
            require(report['certificateFilesPrivate'], 'Fixture certificate file permissions')
    finally:
        report['temporaryCredentialsRemoved'] = temporary_path is not None and not temporary_path.exists()
    require(report['temporaryCredentialsRemoved'], 'Temporary credentials remain')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--openssl', type=Path, default=Path(shutil.which('openssl') or '/nonexistent'))
    parser.add_argument('--output', type=Path, default=Path('build/authenticated-network-probe.json'))
    args = parser.parse_args()
    report = {'reportVersion': 1, 'status': 'failed', 'phase': 'starting',
              'capturedAtUTC': datetime.now(timezone.utc).isoformat()}
    helper.write_report(args.output, report)  # Invalidate any older success before starting.
    status = 1
    try:
        report['phase'] = 'loopback-mtls'
        experiment(args.openssl, report)
        report['status'], report['phase'], status = 'passed', 'complete', 0
    except (ValueError, OSError, subprocess.SubprocessError, UnicodeError, http.client.HTTPException) as error:
        report['failureType'] = type(error).__name__
        print('Authenticated network probe failed: ' + type(error).__name__, file=sys.stderr)
    finally:
        helper.write_report(args.output, report)
    if status == 0:
        print('PASS loopback mTLS: ' + str(len(report['cases'])) +
              ' synthetic-policy cases; no Apple client, Codex or WAN.')
    return status


if __name__ == '__main__':
    sys.exit(main())
