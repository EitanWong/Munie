#!/usr/bin/env python3
"""Bounded, opt-in local-key CSR -> native URLSession loopback mTLS evidence.

Only synthetic CA/server keys are written in a private temporary directory.
The independently compiled Swift driver owns its device key in memory. No CSR,
certificate, key, raw native stream or TLS secret is copied into the report.
This is an experiment runner, not a reusable or deployable TLS service.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time


TOTAL_SECONDS = 150
COMMAND_SECONDS = 10
DRIVER_SECONDS = 100
FRAME_SECONDS = 12
MAX_FRAME = 8192
MAX_STREAM = 65_536
MAX_CERT = 16_384
MAX_CONNECTIONS = 32
IO_SECONDS = 4
CASE_SPECS = (
    ('valid', 'valid.der', 'ca.der'),
    ('repeat-valid', 'valid.der', 'ca.der'),
    ('unknown-same-ca', 'unknown.der', 'ca.der'),
    ('wrong-ca', 'untrusted.der', 'ca.der'),
    ('expired', 'expired.der', 'ca.der'),
    ('wrong-eku', 'wrong-eku.der', 'ca.der'),
    ('no-cert', None, 'ca.der'),
    ('wrong-server-anchor', 'valid.der', 'other-ca.der'),
    ('wrong-server-hostname', 'valid.der', 'ca.der'),
)
HEX = re.compile(r'[0-9a-f]{64}\Z')


class ProbeFailure(Exception):
    """Only fixed, non-sensitive codes are emitted into the report."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(value, code):
    if not value:
        raise ProbeFailure(code)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def strict_json(data):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'duplicate-json-member')
            value[key] = item
        return value

    try:
        result = json.loads(data.decode('utf-8'), object_pairs_hook=unique,
                            parse_constant=lambda _: (_ for _ in ()).throw(
                                ProbeFailure('non-finite-json')))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ProbeFailure('invalid-json') from error
    require(type(result) is dict, 'json-object-required')
    return result


def private_file(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(value if isinstance(value, bytes) else value.encode('utf-8'))


def read_fixture(path, maximum=MAX_CERT):
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= maximum,
                'fixture-file-shape')
        value = stream.read(maximum + 1)
    require(0 < len(value) <= maximum, 'fixture-file-limit')
    return value


def group_gone(pid):
    try:
        os.killpg(pid, 0)
        return False
    except ProcessLookupError:
        return True
    except PermissionError:
        return False


class BoundedProcess:
    """Bound both pipes, writes, time, EOF and the private process group."""

    def __init__(self, command, root, environment, seconds, total_deadline):
        self.deadline = min(time.monotonic() + seconds, total_deadline)
        self.process = subprocess.Popen(
            command, cwd=root, env=environment, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.output = {'stdout': bytearray(), 'stderr': bytearray()}
        self.totals = {'stdout': 0, 'stderr': 0}
        self.digests = {'stdout': hashlib.sha256(), 'stderr': hashlib.sha256()}
        self.eof = {'stdout': False, 'stderr': False}
        self.cleanup = None
        self.overflow = False
        os.set_blocking(self.process.stdin.fileno(), False)
        for stream, label in ((self.process.stdout, 'stdout'), (self.process.stderr, 'stderr')):
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ, label)

    def pump(self, seconds, *, enforce=True):
        for key, _ in self.selector.select(max(0, min(seconds, .2))):
            data = os.read(key.fileobj.fileno(), 8192)
            label = key.data
            if not data:
                self.selector.unregister(key.fileobj)
                self.eof[label] = True
                continue
            self.totals[label] += len(data)
            self.digests[label].update(data)
            remaining = MAX_STREAM - len(self.output[label])
            self.output[label].extend(data[:max(0, remaining)])
            if self.totals[label] > MAX_STREAM:
                self.overflow = True
                if enforce:
                    raise ProbeFailure('process-output-limit')

    def send(self, value, seconds=3):
        require(len(value) <= MAX_FRAME, 'process-input-limit')
        deadline = min(self.deadline, time.monotonic() + seconds)
        offset = 0
        while offset < len(value):
            require(time.monotonic() < deadline, 'process-write-deadline')
            try:
                count = os.write(self.process.stdin.fileno(), value[offset:])
                require(count > 0, 'process-stdin-closed')
                offset += count
            except BlockingIOError:
                self.pump(.05)
            except BrokenPipeError as error:
                raise ProbeFailure('process-stdin-closed') from error

    def close_input(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()

    def frame(self, seconds=FRAME_SECONDS):
        deadline = min(self.deadline, time.monotonic() + seconds)
        while True:
            buffer = self.output['stdout']
            position = buffer.find(b'\n')
            if position >= 0:
                require(position <= MAX_FRAME, 'driver-frame-limit')
                line = bytes(buffer[:position])
                del buffer[:position + 1]
                return strict_json(line)
            require(len(buffer) <= MAX_FRAME, 'driver-frame-limit')
            require(not self.eof['stdout'], 'driver-premature-eof')
            require(time.monotonic() < deadline, 'driver-frame-deadline')
            self.pump(min(.2, deadline - time.monotonic()))

    def finish(self):
        self.close_input()
        while self.process.poll() is None or not all(self.eof.values()):
            require(time.monotonic() < self.deadline, 'process-total-deadline')
            self.pump(.1)
        return self.process.returncode

    def close(self):
        if self.cleanup is not None:
            return self.cleanup
        self.close_input()
        escalated = False
        cleanup_errors = []
        # The process may have failed validation while still running. Drain even
        # after an output-limit failure, without retaining any additional data.
        for candidate in (None, signal.SIGTERM, signal.SIGKILL):
            self.process.poll()
            if candidate is not None:
                try:
                    os.killpg(self.process.pid, candidate)
                    escalated = True
                except ProcessLookupError:
                    pass
                except OSError as error:
                    cleanup_errors.append(error.errno)
            deadline = time.monotonic() + (1 if candidate is None else 2)
            while time.monotonic() < deadline:
                try:
                    self.pump(.05, enforce=False)
                except OSError as error:
                    cleanup_errors.append(error.errno)
                    break
                self.process.poll()
                if self.process.returncode is not None and all(self.eof.values()) and group_gone(self.process.pid):
                    break
            if self.process.returncode is not None and all(self.eof.values()) and group_gone(self.process.pid):
                break
        try:
            self.process.wait(timeout=.5)
        except subprocess.TimeoutExpired:
            cleanup_errors.append('reap-deadline')
        gone = group_gone(self.process.pid)
        self.cleanup = {
            'exitStatus': self.process.returncode, 'stdoutEOF': self.eof['stdout'],
            'stderrEOF': self.eof['stderr'], 'streamsReachedEOF': all(self.eof.values()),
            'processGroupGone': gone, 'escalated': escalated,
            'stdoutBytes': self.totals['stdout'], 'stderrBytes': self.totals['stderr'],
            'stdoutSHA256': self.digests['stdout'].hexdigest(),
            'stderrSHA256': self.digests['stderr'].hexdigest(),
            'outputWithinLimits': not self.overflow, 'errors': cleanup_errors,
        }
        for stream in (self.process.stdout, self.process.stderr):
            stream.close()
        self.selector.close()
        return self.cleanup


class OpenSSL:
    def __init__(self, executable, root, report, deadline):
        self.executable, self.root, self.report, self.deadline = executable, root, report, deadline
        self.environment = {
            'PATH': '/usr/bin:/bin', 'LANG': 'C', 'LC_ALL': 'C',
            'OPENSSL_CONF': str(root / 'empty.cnf'), 'TMPDIR': str(root),
        }

    def run(self, label, *arguments, input_bytes=None, success=True, safe_diagnostic=False):
        require(time.monotonic() < self.deadline, 'experiment-total-deadline')
        peer = BoundedProcess([str(self.executable), *arguments], self.root,
                              self.environment, COMMAND_SECONDS, self.deadline)
        try:
            if input_bytes is not None:
                peer.send(input_bytes)
            status = peer.finish()
            output = bytes(peer.output['stdout'])
            errors = bytes(peer.output['stderr'])
        finally:
            cleanup = peer.close()
            record = {'stage': label, 'argv': [str(self.executable), *arguments],
                      'cleanup': cleanup}
            if safe_diagnostic:
                allowed = {
                    b'Certificate request self-signature verify OK',
                    b'Certificate request self-signature verify failure',
                    b'verify OK', b'verify failure',
                }
                record['literalSafeDiagnostics'] = [
                    line.decode('ascii') for stream in peer.output.values()
                    for line in bytes(stream).splitlines() if line in allowed]
            self.report['commands'].append(record)
        require(cleanup['streamsReachedEOF'] and cleanup['processGroupGone'] and
                cleanup['outputWithinLimits'] and not cleanup['errors'], 'openssl-cleanup')
        require((status == 0) if success else (status != 0), 'openssl-unexpected-status-' + label)
        return output, errors


def prepare_certificates(openssl, root, ready, report):
    csr = read_fixture(root / 'device.csr.der')
    require(sha(csr) == ready['csrSHA256'], 'csr-file-digest-mismatch')
    openssl.run('csr-signature-valid', 'req', '-inform', 'DER', '-in', 'device.csr.der',
                '-verify', '-noout', safe_diagnostic=True)
    corrupted = bytearray(csr)
    corrupted[-1] ^= 1
    private_file(root / 'tampered.csr.der', bytes(corrupted))
    openssl.run('csr-signature-tampered', 'req', '-inform', 'DER', '-in', 'tampered.csr.der',
                '-verify', '-noout', success=False, safe_diagnostic=True)
    public_pem, _ = openssl.run('csr-public-key', 'req', '-inform', 'DER', '-in',
                                'device.csr.der', '-pubkey', '-noout')
    public_der, _ = openssl.run('csr-public-spki', 'pkey', '-pubin', '-outform', 'DER',
                                input_bytes=public_pem)
    require(sha(public_der) == ready['publicKeySHA256'], 'csr-key-digest-mismatch')
    key_description, _ = openssl.run('csr-key-profile', 'pkey', '-pubin', '-text', '-noout',
                                     input_bytes=public_pem)
    require(b'(256 bit' in key_description and b'ASN1 OID: prime256v1' in key_description,
            'csr-key-not-p256')
    openssl.run('csr-to-pem', 'req', '-inform', 'DER', '-in', 'device.csr.der',
                '-out', 'device.csr.pem')
    report['csr'] = {'signatureVerified': True, 'tamperedSignatureRejected': True,
                     'keyMatched': True, 'keyBits': 256, 'publicKeyEncoding': 'spki-der',
                     'csrSHA256': sha(csr), 'publicKeySHA256': sha(public_der),
                     'csrBytes': len(csr)}

    ca_config = ('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ca\n'
                 '[dn]\nCN=Munie Synthetic Local Key Fixture CA\n[ca]\n'
                 'basicConstraints=critical,CA:true,pathlen:0\n'
                 'keyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n'
                 'authorityKeyIdentifier=keyid:always\n')
    for name in ('ca', 'other-ca'):
        private_file(root / (name + '.cnf'), ca_config)
        openssl.run(name + '-create', 'req', '-x509', '-newkey', 'ec', '-pkeyopt',
                    'ec_paramgen_curve:prime256v1', '-nodes', '-days', '2', '-sha256',
                    '-config', name + '.cnf', '-keyout', name + '.key', '-out', name + '.pem')
        openssl.run(name + '-der', 'x509', '-in', name + '.pem', '-outform', 'DER',
                    '-out', name + '.der')
    profiles = ('[client]\nbasicConstraints=critical,CA:false\n'
                'keyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n'
                'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
                '[wrong]\nbasicConstraints=critical,CA:false\n'
                'keyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n'
                'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
                '[server]\nbasicConstraints=critical,CA:false\n'
                'keyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n'
                'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
                'subjectAltName=IP:127.0.0.1\n'
                '[wrong-host]\nbasicConstraints=critical,CA:false\n'
                'keyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n'
                'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
                'subjectAltName=DNS:localhost\n')
    private_file(root / 'profiles.cnf', profiles)
    openssl.run('server-csr', 'req', '-new', '-newkey', 'ec', '-pkeyopt',
                'ec_paramgen_curve:prime256v1', '-nodes', '-subj', '/CN=Munie Synthetic Loopback',
                '-keyout', 'server.key', '-out', 'server.csr.pem')
    leaves = (
        ('server', 'server.csr.pem', 'ca', 'server', 100),
        ('wrong-host-server', 'server.csr.pem', 'ca', 'wrong-host', 106),
        ('valid', 'device.csr.pem', 'ca', 'client', 101),
        ('unknown', 'device.csr.pem', 'ca', 'client', 102),
        ('untrusted', 'device.csr.pem', 'other-ca', 'client', 103),
        ('wrong-eku', 'device.csr.pem', 'ca', 'wrong', 104),
    )
    for name, request, issuer, profile, serial in leaves:
        openssl.run(name + '-sign', 'x509', '-req', '-in', request, '-CA', issuer + '.pem',
                    '-CAkey', issuer + '.key', '-set_serial', str(serial), '-days', '1',
                    '-sha256', '-extfile', 'profiles.cnf', '-extensions', profile,
                    '-out', name + '.pem')
    private_file(root / 'expired-index.txt', '')
    private_file(root / 'expired-serial', '0105\n')
    (root / 'expired-certs').mkdir(mode=0o700)
    private_file(root / 'expired-ca.cnf',
                 '[ca]\ndefault_ca=fixture\n[fixture]\ndatabase=expired-index.txt\n'
                 'new_certs_dir=expired-certs\ncertificate=ca.pem\nprivate_key=ca.key\n'
                 'serial=expired-serial\ndefault_md=sha256\npolicy=subject_policy\n'
                 'unique_subject=no\ncopy_extensions=none\n[subject_policy]\ncommonName=supplied\n'
                 '[client]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n'
                 'extendedKeyUsage=clientAuth\nsubjectKeyIdentifier=hash\n'
                 'authorityKeyIdentifier=keyid,issuer\n')
    openssl.run('expired-sign', 'ca', '-batch', '-config', 'expired-ca.cnf', '-in',
                'device.csr.pem', '-out', 'expired.pem', '-notext', '-extensions', 'client',
                '-startdate', '20000101000000Z', '-enddate', '20000102000000Z')
    fingerprints = {}
    for name in ('valid', 'unknown', 'untrusted', 'expired', 'wrong-eku'):
        openssl.run(name + '-der', 'x509', '-in', name + '.pem', '-outform', 'DER',
                    '-out', name + '.der')
        fingerprints[name] = sha(read_fixture(root / (name + '.der')))
        candidate_pem, _ = openssl.run(name + '-public-key', 'x509', '-in', name + '.pem',
                                       '-pubkey', '-noout')
        candidate_der, _ = openssl.run(name + '-public-spki', 'pkey', '-pubin',
                                       '-outform', 'DER', input_bytes=candidate_pem)
        require(candidate_der == public_der, 'signed-leaf-key-mismatch')
    for name in ('valid', 'unknown'):
        openssl.run(name + '-profile-valid', 'verify', '-x509_strict', '-CAfile', 'ca.pem',
                    '-purpose', 'sslclient', name + '.pem')
    for name in ('expired', 'wrong-eku', 'untrusted'):
        openssl.run(name + '-profile-rejected', 'verify', '-x509_strict', '-CAfile', 'ca.pem',
                    '-purpose', 'sslclient', name + '.pem', success=False)
    openssl.run('server-profile-valid', 'verify', '-x509_strict', '-CAfile', 'ca.pem',
                '-purpose', 'sslserver', '-verify_ip', '127.0.0.1', 'server.pem')
    openssl.run('server-wrong-anchor', 'verify', '-CAfile', 'other-ca.pem',
                '-purpose', 'sslserver', 'server.pem', success=False)
    for path in root.rglob('*'):
        path.chmod(0o700 if path.is_dir() else 0o600)
    report['certificates'] = {'allDeviceLeavesUseCSRKey': True, 'leafSHA256': fingerprints,
                              'expiredValidityUTC': ['2000-01-01', '2000-01-02'],
                              'serverIP': '127.0.0.1', 'privateKeysPersisted': 'synthetic-issuer-server-only'}
    return fingerprints


class FixtureServer:
    """One bounded worker on an ephemeral loopback socket; never a product server."""

    def __init__(self, root, valid_fingerprint, certificate_name="server.pem"):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_3
        context.maximum_version = ssl.TLSVersion.TLSv1_3
        context.verify_mode = ssl.CERT_REQUIRED
        context.verify_flags |= ssl.VERIFY_X509_STRICT
        context.load_verify_locations(cafile=str(root / 'ca.pem'))
        context.load_cert_chain(str(root / certificate_name), str(root / 'server.key'))
        context.set_alpn_protocols(['http/1.1'])
        context.num_tickets = 0
        require(context.keylog_filename is None, 'tls-secret-logging-enabled')
        self.context, self.valid_fingerprint = context, valid_fingerprint
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.listener.bind(('127.0.0.1', 0))
            self.listener.listen(4)
            self.listener.settimeout(.2)
            self.port = self.listener.getsockname()[1]
            self.lock = threading.Lock()
            self.active = None
            self.stopping = threading.Event()
            self.records = []
            self.fatal = None
            self.thread = threading.Thread(target=self.serve, name='munie-local-key-tls', daemon=True)
            self.thread.start()
        except BaseException:
            # A failed initializer is never assigned to experiment's owner, so
            # it must close its own listener rather than rely on outer cleanup.
            self.listener.close()
            raise

    def serve(self):
        try:
            while not self.stopping.is_set():
                try:
                    raw, address = self.listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    if self.stopping.is_set():
                        break
                    raise
                record = {'connection': len(self.records) + 1, 'loopback': address[0] == '127.0.0.1',
                          'handshake': False, 'businessRequest': False}
                self.records.append(record)
                if len(self.records) > MAX_CONNECTIONS:
                    raw.close()
                    raise ProbeFailure('server-connection-limit')
                secured = None
                try:
                    raw.settimeout(IO_SECONDS)
                    with self.lock:
                        if self.stopping.is_set():
                            raw.close()
                            break
                        self.active = raw
                    secured = self.context.wrap_socket(raw, server_side=True,
                                                       do_handshake_on_connect=False)
                    with self.lock:
                        self.active = secured
                        if self.stopping.is_set():
                            raise ProbeFailure('server-stopping')
                    secured.do_handshake()
                    record['handshake'] = True
                    record['tlsProtocol'] = secured.version()
                    peer = secured.getpeercert(binary_form=True)
                    require(peer is not None and len(peer) > 0, 'verified-peer-missing')
                    fingerprint = sha(peer)
                    record['peer'] = fingerprint
                    require(secured.version() == 'TLSv1.3', 'server-wrong-tls-version')
                    deadline = time.monotonic() + IO_SECONDS
                    header = bytearray()
                    while b'\r\n\r\n' not in header:
                        require(time.monotonic() < deadline, 'http-header-deadline')
                        secured.settimeout(max(.001, deadline - time.monotonic()))
                        part = secured.recv(min(1024, 4097 - len(header)))
                        require(part, 'http-header-eof')
                        header.extend(part)
                        require(len(header) <= 4096, 'http-header-limit')
                    lines = bytes(header).split(b'\r\n')
                    require(lines[0] == b'GET /fixture HTTP/1.1', 'http-route-method')
                    require(len(lines) <= 36, 'http-header-count')
                    require(not any(line.lower().startswith(b'transfer-encoding:') for line in lines),
                            'http-transfer-encoding')
                    lengths = [line.split(b':', 1)[1].strip() for line in lines
                               if line.lower().startswith(b'content-length:')]
                    require(not lengths or lengths == [b'0'], 'http-body-not-allowed')
                    record['businessRequest'] = True
                    state = 'accepted' if fingerprint == self.valid_fingerprint else 'denied'
                    record['state'] = state
                    body = json.dumps({'state': state, 'peer': fingerprint}, separators=(',', ':')).encode('ascii')
                    require(len(body) <= 2048, 'http-response-limit')
                    response = (b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
                                b'Cache-Control: no-store\r\nConnection: close\r\nContent-Length: '
                                + str(len(body)).encode('ascii') + b'\r\n\r\n' + body)
                    secured.settimeout(IO_SECONDS)
                    secured.sendall(response)
                    record['responseBytes'] = len(body)
                except ssl.SSLCertVerificationError as error:
                    record['error'] = 'certificate-verification'
                    record['verifyCode'] = error.verify_code
                except ssl.SSLError as error:
                    record['error'] = 'tls-rejection'
                    reason = getattr(error, 'reason', '')
                    if re.fullmatch(r'[A-Z0-9_]{1,100}', reason):
                        record['reason'] = reason
                except (OSError, ProbeFailure) as error:
                    if not self.stopping.is_set():
                        record['error'] = error.code if isinstance(error, ProbeFailure) else 'socket-failure'
                        if isinstance(error, OSError):
                            record['errno'] = error.errno
                finally:
                    with self.lock:
                        self.active = None
                    (secured if secured is not None else raw).close()
        except BaseException as error:
            self.fatal = error.code if isinstance(error, ProbeFailure) else type(error).__name__

    def close(self):
        self.stopping.set()
        with self.lock:
            active = self.active
            if active is not None:
                try:
                    active.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                active.close()
        self.listener.close()
        self.thread.join(timeout=IO_SECONDS + 1)
        return {'listenerClosed': self.listener.fileno() == -1,
                'workerStopped': not self.thread.is_alive(), 'activeConnectionClosed': self.active is None,
                'fatal': self.fatal, 'connections': list(self.records)}


def validate_ready(frame):
    keys = {'event', 'keyBits', 'keyPermanent', 'publicKeySHA256', 'publicKeyEncoding', 'csrSHA256'}
    require(set(frame) == keys and frame['event'] == 'csr-ready', 'driver-ready-schema')
    require(type(frame['keyBits']) is int and frame['keyBits'] == 256 and
            frame['keyPermanent'] is False and frame['publicKeyEncoding'] == 'spki-der',
            'driver-ready-key-profile')
    require(all(type(frame[key]) is str and HEX.fullmatch(frame[key])
                for key in ('csrSHA256', 'publicKeySHA256')), 'driver-ready-digest')
    return dict(frame)


def validate_result(frame, expected_name, fingerprints):
    required = {'event', 'name', 'bodyBytes', 'serverChallenges', 'clientChallenges',
                'trustRejected', 'overflow', 'redirectRejected', 'invalidated'}
    optional = {'httpStatus', 'errorCode', 'state', 'peer', 'tlsProtocol', 'proxy'}
    require(required <= frame.keys() <= required | optional and frame['event'] == 'result' and
            frame['name'] == expected_name, 'driver-result-schema')
    require(frame['invalidated'] is True and frame['overflow'] is False and
            frame['redirectRejected'] is False, 'driver-result-session-safety')
    for key in ('bodyBytes', 'serverChallenges', 'clientChallenges', 'trustRejected'):
        require(type(frame[key]) is int and 0 <= frame[key] <= (2048 if key == 'bodyBytes' else 8),
                'driver-result-numeric')
    require(frame['trustRejected'] <= frame['serverChallenges'], 'driver-trust-count')
    for key in ('httpStatus', 'errorCode', 'tlsProtocol'):
        if key in frame:
            require(type(frame[key]) is int, 'driver-result-integer')
    if 'tlsProtocol' in frame:
        require(frame['tlsProtocol'] == 772, 'driver-tls-version')
    if 'proxy' in frame:
        require(frame['proxy'] is False, 'driver-proxy')
    if expected_name in ('valid', 'repeat-valid', 'unknown-same-ca'):
        state = 'denied' if expected_name == 'unknown-same-ca' else 'accepted'
        fingerprint = fingerprints['unknown' if state == 'denied' else 'valid']
        require(frame.get('httpStatus') == 200 and 'errorCode' not in frame and
                frame.get('tlsProtocol') == 772 and frame.get('proxy') is False and
                frame.get('state') == state and frame.get('peer') == fingerprint and
                frame['bodyBytes'] > 0 and frame['serverChallenges'] > 0 and
                frame['clientChallenges'] > 0 and frame['trustRejected'] == 0,
                'driver-http-outcome')
    else:
        require('httpStatus' not in frame and 'state' not in frame and 'peer' not in frame and
                frame['bodyBytes'] == 0, 'rejected-case-reached-http')
        if expected_name in ('wrong-server-anchor', 'wrong-server-hostname'):
            require(frame.get('errorCode') in {-999, -1200, -1202} and
                    frame['serverChallenges'] > 0 and frame['trustRejected'] > 0 and
                    frame['clientChallenges'] == 0,
                    'driver-server-trust-control')
        else:
            require(frame.get('errorCode') in {-999, -1005, -1200, -1205, -1206} and
                    frame['clientChallenges'] > 0 and frame['trustRejected'] == 0,
                    'driver-client-certificate-control')
    return dict(frame)


def validate_done(frame):
    keys = {'event', 'sessionsInvalidated', 'certificateKeyMatched', 'identityLeafMatched',
            'identityPossessionVerified', 'mismatchedIdentityRejected', 'keychainUsed', 'privateKeyExported'}
    require(set(frame) == keys and frame['event'] == 'done' and
            type(frame['sessionsInvalidated']) is int and frame['sessionsInvalidated'] == len(CASE_SPECS),
            'driver-done-schema')
    for key in ('certificateKeyMatched', 'identityLeafMatched', 'identityPossessionVerified',
                'mismatchedIdentityRejected'):
        require(frame[key] is True, 'driver-identity-check')
    require(frame['keychainUsed'] is False and frame['privateKeyExported'] is False,
            'driver-key-lifecycle-check')
    return dict(frame)


def validate_server(cleanup, fingerprints):
    require(cleanup['listenerClosed'] and cleanup['workerStopped'] and
            cleanup['activeConnectionClosed'] and cleanup['fatal'] is None, 'server-cleanup')
    records = cleanup['connections']
    require(3 <= len(records) <= MAX_CONNECTIONS and all(item['loopback'] for item in records),
            'server-connection-evidence')
    requests = [item for item in records if item['businessRequest']]
    accepted = [item for item in requests if item.get('state') == 'accepted']
    denied = [item for item in requests if item.get('state') == 'denied']
    require(len(requests) == 3 and len(accepted) == 2 and len(denied) == 1,
            'server-business-count')
    require(all(item['peer'] == fingerprints['valid'] for item in accepted) and
            denied[0]['peer'] == fingerprints['unknown'], 'server-actual-peer-binding')
    require(all(item.get('tlsProtocol') == 'TLSv1.3' for item in requests), 'server-http-tls')
    require(all(not item['businessRequest'] for item in records if not item['handshake']),
            'server-rejected-peer-business')
    return {'handshakeAttempts': len(records),
            'successfulHandshakes': sum(item['handshake'] for item in records),
            'businessRequests': len(requests), 'accepted': len(accepted), 'denied': len(denied),
            'onlyActualVerifiedPeerUsed': True}


def experiment(driver, executable, report):
    deadline = time.monotonic() + TOTAL_SECONDS
    root = Path(tempfile.mkdtemp(prefix='munie-local-key-mtls-'))
    root.chmod(0o700)
    peer = server = hostname_server = None
    fingerprints = None
    failure = None
    report['cleanup'] = {}
    try:
        private_file(root / 'empty.cnf', '')
        openssl = OpenSSL(executable, root, report, deadline)
        version, _ = openssl.run('openssl-version', 'version')
        require(len(version) <= 512 and b'OpenSSL' in version, 'openssl-version')
        report['opensslVersion'] = version.decode('ascii').strip()
        environment = {'PATH': '/usr/bin:/bin', 'LANG': 'C', 'LC_ALL': 'C', 'TMPDIR': str(root)}
        peer = BoundedProcess([str(driver), str(root)], root, environment, DRIVER_SECONDS, deadline)
        ready = validate_ready(peer.frame())
        report['driverReady'] = ready
        fingerprints = prepare_certificates(openssl, root, ready, report)
        server = FixtureServer(root, fingerprints['valid'])
        hostname_server = FixtureServer(root, fingerprints['valid'], 'wrong-host-server.pem')
        configuration = {'port': server.port, 'anchor': 'ca.der', 'cases': [
            {'name': name, 'certificate': certificate, 'anchor': anchor,
             'port': hostname_server.port if name == 'wrong-server-hostname' else server.port}
            for name, certificate, anchor in CASE_SPECS]}
        peer.send(json.dumps(configuration, separators=(',', ':')).encode('ascii') + b'\n')
        peer.close_input()
        for name, _, _ in CASE_SPECS:
            report['cases'].append(validate_result(peer.frame(), name, fingerprints))
        report['driverDone'] = validate_done(peer.frame())
        require(peer.finish() == 0, 'driver-exit-status')
        require(not peer.output['stdout'], 'driver-trailing-output')
        require(peer.totals['stderr'] == 0, 'driver-stderr-not-empty')
    except BaseException as error:
        failure = error
    finally:
        # Native clients first, then sockets/listener/worker, then all temporary
        # identities/CSR/issuer/server keys. Never skip cleanup after a failure.
        if peer is not None:
            try:
                report['cleanup']['driver'] = peer.close()
            except BaseException as error:
                report['cleanup']['driverCleanupError'] = type(error).__name__
                failure = failure or error
        if server is not None:
            try:
                report['cleanup']['server'] = server.close()
            except BaseException as error:
                report['cleanup']['serverCleanupError'] = type(error).__name__
                failure = failure or error
        if hostname_server is not None:
            try:
                report['cleanup']['hostnameServer'] = hostname_server.close()
            except BaseException as error:
                report['cleanup']['hostnameServerCleanupError'] = type(error).__name__
                failure = failure or error
        try:
            shutil.rmtree(root)
        except OSError as error:
            report['cleanup']['temporaryRemovalErrno'] = error.errno
        report['cleanup']['temporaryDirectoryRemoved'] = not root.exists()
        report['cleanup']['temporaryCredentialFilesRemoved'] = not root.exists()
    cleanup = report['cleanup']
    if failure is not None:
        raise failure
    driver_cleanup = cleanup.get('driver', {})
    require(driver_cleanup.get('exitStatus') == 0 and driver_cleanup.get('streamsReachedEOF') and
            driver_cleanup.get('processGroupGone') and driver_cleanup.get('outputWithinLimits') and
            not driver_cleanup.get('errors'), 'driver-cleanup')
    require(cleanup.get('temporaryDirectoryRemoved') and cleanup.get('temporaryCredentialFilesRemoved'),
            'temporary-credential-cleanup')
    report['serverEvidence'] = validate_server(cleanup['server'], fingerprints)
    hostname = cleanup['hostnameServer']
    require(hostname['listenerClosed'] and hostname['workerStopped'] and
            hostname['activeConnectionClosed'] and hostname['fatal'] is None and
            1 <= len(hostname['connections']) <= 3 and
            all(item['loopback'] and not item['businessRequest'] for item in hostname['connections']),
            'hostname-control-cleanup-or-business')
    report['hostnameControl'] = {'actualWrongSANServer': True, 'businessRequests': 0,
                                 'handshakeAttempts': len(hostname['connections'])}


def save_report(path, report):
    encoded = (json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + '\n').encode('utf-8')
    require(len(encoded) <= 262_144, 'report-size-limit')
    private_file(path, encoded)
    require(path.read_bytes() == encoded, 'report-reopen-mismatch')
    return {'path': str(path), 'bytes': len(encoded), 'sha256': sha(encoded), 'passed': report['passed']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report_path = args.report.expanduser().absolute()
    # Never overwrite old evidence or execute before an output location is usable.
    if report_path.exists() or not report_path.parent.is_dir():
        print(json.dumps({'passed': False, 'failure': 'report-path-not-fresh'}))
        return 2
    driver = args.driver.expanduser().resolve()
    candidate = Path('/opt/homebrew/bin/openssl')
    openssl = candidate if candidate.is_file() else Path(shutil.which('openssl') or '/nonexistent')
    report = {
        'schemaVersion': 1, 'experiment': 'synthetic-local-key-csr-loopback-mtls', 'passed': False,
        'utcStarted': datetime.now(timezone.utc).isoformat(),
        'runnerSHA256': sha(Path(__file__).read_bytes()), 'driver': str(driver),
        'python': sys.version.split()[0], 'pythonExecutable': sys.executable,
        'pythonTLS': ssl.OPENSSL_VERSION, 'pythonTLS13': ssl.HAS_TLSv1_3,
        'networkScope': '127.0.0.1-only', 'commands': [], 'cases': [],
        'limits': {'experimentSeconds': TOTAL_SECONDS, 'driverSeconds': DRIVER_SECONDS,
                   'commandSeconds': COMMAND_SECONDS, 'frameSeconds': FRAME_SECONDS,
                   'frameBytes': MAX_FRAME, 'streamBytes': MAX_STREAM, 'connections': MAX_CONNECTIONS,
                   'handshakeSeconds': IO_SECONDS, 'headerSeconds': IO_SECONDS,
                   'responseBytes': 2048},
        'scopeLimits': ['memory-only-macOS-device-key', 'synthetic-issuer-server-keys-on-temporary-disk',
                        'no-product-enrollment-or-service', 'no-Keychain-persistence-evidence',
                        'no-device-Watch-WAN-model-account-or-power-loss-evidence'],
    }
    old_umask = os.umask(0o077)
    def terminated(_signum, _frame):
        raise ProbeFailure('runner-terminated')
    prior_sigterm = signal.signal(signal.SIGTERM, terminated)
    try:
        require(driver.is_file() and os.access(driver, os.X_OK), 'driver-not-executable')
        require(openssl.is_file() and os.access(openssl, os.X_OK), 'openssl-not-executable')
        require(ssl.HAS_TLSv1_3, 'python-tls13-unavailable')
        report['driverSHA256'] = sha(driver.read_bytes())
        experiment(driver, openssl, report)
        report['passed'] = True
    except BaseException as error:
        report['failure'] = error.code if isinstance(error, ProbeFailure) else type(error).__name__
        if isinstance(error, OSError):
            report['failureErrno'] = error.errno
    finally:
        os.umask(old_umask)
        signal.signal(signal.SIGTERM, prior_sigterm)
        report['utcFinished'] = datetime.now(timezone.utc).isoformat()
    try:
        summary = save_report(report_path, report)
    except (OSError, ProbeFailure):
        print(json.dumps({'passed': False, 'failure': 'report-write-failed'}))
        return 2
    print(json.dumps(summary, sort_keys=True))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
