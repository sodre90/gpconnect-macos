#!/usr/bin/env python3

import webview

import argparse
import threading
import time
import re
import requests
import xml.etree.ElementTree as ET
import ssl
import tempfile

from os import path, dup2, execvp
from shlex import quote
from sys import stderr, platform
from binascii import a2b_base64, b2a_base64
from urllib.parse import urlparse, urlencode
from uuid import uuid1


class SAMLLoginView:
    def __init__(self, uri=None, html=None, verbose=False, user_agent=None):
        self.closed = False
        self.success = False
        self.saml_result = {}
        self.verbose = verbose

        self.lock = threading.Lock()

        self.window = window = webview.create_window('SAML Login', width=500, height=500)
        webview.start(self.create_login_window,
            [window, uri, html],
            user_agent='PAN GlobalProtect' if user_agent is None else user_agent,
            debug=verbose,
            private_mode=False)

        # pywebview 5.x on macOS can return from webview.start() before the
        # WindowServer has committed the window's close, leaving a ghost window
        # on screen once the main thread blocks elsewhere (e.g. the daemon log
        # loop). Pump the main run loop briefly so the pending teardown flushes.
        if platform == 'darwin':
            try:
                from Foundation import NSRunLoop, NSDate
                NSRunLoop.currentRunLoop().runUntilDate_(
                    NSDate.dateWithTimeIntervalSinceNow_(0.2))
            except Exception:
                pass

    def create_login_window(self, window, uri, html):
        window.events.closed += self.on_closed
        window.events.loaded += self.get_saml_headers
        if not html is None:
            window.load_html(html)
        else:
            window.load_url(uri)

    def on_closed(self):
        if self.verbose > 2:
            print('[WEBVIEW] Window closed', file=stderr)
        self.closed = not self.success

    def get_saml_headers(self):
        window = self.window
        self.lock.acquire()
        if self.verbose > 1:
            print('[PAGE   ] Page loaded in thread %x' % threading.get_ident(), file=stderr)
        uri = window.get_current_url()
        if self.verbose:
            print('[PAGE   ] Loaded URI: %s' % uri, file=stderr)
        # Use 'window.gui.evaluate_js' to bypass pywebview's 'var value = eval("{0}")' closure, which triggers:
        #
        #     Refused to evaluate a string as JavaScript because 'unsafe-eval' is not an allowed source of
        #     script in the following Content Security Policy directive: "script-src 'self' 'unsafe-inline'".
        js = 'var value = document.documentElement.outerHTML;\n'
        if window.gui.renderer == 'cef':
            unique_id = uuid1().hex
            js += 'window.external.return_result(JSON.stringify(value), "{0}");'.format(unique_id)
            html = window.gui.evaluate_js(js, window.uid, unique_id)
        else:
            js += 'JSON.stringify(value);'
            html = window.gui.evaluate_js(js, window.uid)
        if self.verbose > 2:
            print('[PAGE   ] Retrieved outerHTML: %s' % html, file=stderr)
        if not html:
            self.lock.release()
            return
        # In addition to their HTTP header counterparts (which aren't surfaced by pywebview), GlobalProtect adds the
        # following values to the body of its response after authentication succeeds (line breaks added for clarity):
        #
        #     <saml-auth-status>{{STATUS}}</saml-auth-status>
        #     <prelogin-cookie>{{COOKIE}}</prelogin-cookie>
        #     <saml-username>{{USERNAME}}</saml-username>
        #     <saml-slo>{{SLO}}</saml-slo>
        fd = {}
        for m in re.finditer('<(?P<header>saml-.+?|(?:prelogin-|portal-userauth)cookie)>(?P<value>.*?)</(?P=header)>', html):
            fd[m.group('header')] = m.group('value')
        if not fd:
            self.lock.release()
            return
        if self.verbose:
            print("[SAML   ] Got SAML result headers: %r" % fd, file=stderr)

        # check if we're done
        self.saml_result.update(fd, server=urlparse(uri).netloc)
        self.lock.release()
        time.sleep(1)
        self.check_done()

    def check_done(self):
        self.lock.acquire()
        d = self.saml_result
        if 'saml-username' in d and ('prelogin-cookie' in d or 'portal-userauthcookie' in d):
            if self.verbose:
                print("[SAML   ] Got all required SAML headers, done.", file=stderr)
            self.success = True
            self.window.destroy()
        self.lock.release()


def parse_args(args = None):
    pf2clientos = dict(linux='Linux', darwin='Mac', win32='Windows', cygwin='Windows')
    clientos2ocos = dict(Linux='linux-64', Mac='mac-intel', Windows='win')
    default_clientos = pf2clientos.get(platform, 'Windows')

    p = argparse.ArgumentParser()
    p.add_argument('server', help='GlobalProtect server (portal or gateway)')
    x = p.add_mutually_exclusive_group()
    x.add_argument('-g','--gateway', dest='interface', action='store_const', const='gateway', default='portal',
                   help='SAML auth to gateway')
    x.add_argument('-p','--portal', dest='interface', action='store_const', const='portal',
                   help='SAML auth to portal (default)')
    g = p.add_argument_group('Client certificate')
    g.add_argument('-c','--cert', help='PEM file containing client certificate (and optionally private key)')
    g.add_argument('--key', help='PEM file containing client private key (if not included in same file as certificate)')
    g = p.add_argument_group('Debugging and advanced options')
    x = p.add_mutually_exclusive_group()
    x.add_argument('-v','--verbose', default=1, action='count', help='Increase verbosity of explanatory output to stderr')
    x.add_argument('-q','--quiet', dest='verbose', action='store_const', const=0, help='Reduce verbosity to a minimum')
    x = p.add_mutually_exclusive_group()
    x.add_argument('-x','--external', action='store_true', help='Launch external browser (for debugging)')
    x.add_argument('-S','--sudo-openconnect', action='store_const', dest='exec', const='sudo', help='Use sudo to exec openconnect')
    x.add_argument('-D','--daemon-openconnect', action='store_const', dest='exec', const='daemon', help='Use privileged helper daemon to exec openconnect (no sudo needed after helper/install.sh)')
    g.add_argument('-u','--uri', action='store_true', help='Treat server as the complete URI of the SAML entry point, rather than GlobalProtect server')
    g.add_argument('--clientos', choices=set(pf2clientos.values()), default=default_clientos, help="clientos value to send (default is %(default)s)")
    p.add_argument('-f','--field', dest='extra', action='append', default=[],
                   help='Extra form field(s) to pass to include in the login query string (e.g. "-f magic-cookie-value=deadbeef01234567")')
    p.add_argument('--allow-insecure-crypto', dest='insecure', action='store_true',
                   help='Allow use of insecure renegotiation or ancient 3DES and RC4 ciphers')
    p.add_argument('--no-verify', dest='verify', action='store_false', default=True,
                   help="Don't verify the gateway's TLS certificate (affects this script's requests, not the SAML webview)")
    p.add_argument('--user-agent', '--useragent', default='PAN GlobalProtect',
                   help='Use the provided string as the HTTP User-Agent header (default is %(default)r, as used by OpenConnect)')
    p.add_argument('openconnect_extra', nargs='*', help="Extra arguments to include in output OpenConnect command-line")
    args = p.parse_args(args)

    args.ocos = clientos2ocos[args.clientos]
    args.extra = dict(x.split('=', 1) for x in args.extra)

    if args.cert and args.key:
        args.cert, args.key = (args.cert, args.key), None
    elif args.cert:
        args.cert = (args.cert, None)
    elif args.key:
        p.error('--key specified without --cert')
    else:
        args.cert = None

    return p, args

class SSLContextAdapter(requests.adapters.HTTPAdapter):
    '''Adapt to older TLS stacks (e.g. GlobalProtect gateways) that would raise errors otherwise.

    Always enables unsafe legacy renegotiation for servers without RFC 5746 support. If verify=False
    (--no-verify), also skips certificate and hostname validation, for gateways presenting a
    certificate that doesn't chain to a trusted root. If insecure=True (--allow-insecure-crypto), also enables weak ciphers
    such as 3DES or RC4 and weak Diffie-Hellman key exchange sizes, which OpenSSL 3.0+ disables by
    default (see https://github.com/psf/requests/issues/4775#issuecomment-478198879).
    '''
    def __init__(self, *args, insecure=False, verify=True, **kwargs):
        self.insecure = insecure
        self.verify = verify
        super().__init__(*args, **kwargs)

    def init_poolmanager(self, *args, **kwargs):
        ctx = ssl.create_default_context()
        ctx.options |= ssl.OP_LEGACY_SERVER_CONNECT
        if not self.verify:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        if self.insecure:
            ctx.set_ciphers('DEFAULT:@SECLEVEL=1')

        kwargs['ssl_context'] = ctx
        return super().init_poolmanager(*args, **kwargs)

def main(args = None):
    p, args = parse_args(args)

    s = requests.Session()
    s.mount('https://', SSLContextAdapter(insecure=args.insecure, verify=args.verify))
    s.headers['User-Agent'] = 'PAN GlobalProtect' if args.user_agent is None else args.user_agent
    s.cert = args.cert

    if2prelogin = {'portal':'global-protect/prelogin.esp','gateway':'ssl-vpn/prelogin.esp'}
    if2auth = {'portal':'global-protect/getconfig.esp','gateway':'ssl-vpn/login.esp'}

    # query prelogin.esp and parse SAML bits
    if args.uri:
        sam, uri, html = 'URI', args.server, None
    else:
        endpoint = 'https://{}/{}'.format(args.server, if2prelogin[args.interface])
        data = {'tmp':'tmp', 'kerberos-support':'yes', 'ipv6-support':'yes', 'clientVer':4100, 'clientos':args.clientos, **args.extra}
        if args.verbose:
            print("Looking for SAML auth tags in response to %s..." % endpoint, file=stderr)
        try:
            res = s.post(endpoint, verify=args.verify, data=data)
        except Exception as ex:
            rootex = ex
            while True:
                if isinstance(rootex, ssl.SSLError):
                    break
                elif not rootex.__cause__ and not rootex.__context__:
                    break
                rootex = rootex.__cause__ or rootex.__context__
            if isinstance(rootex, ssl.CertificateError):
                p.error("SSL certificate error (try --no-verify to ignore): %s" % rootex)
            elif isinstance(rootex, ssl.SSLError):
                p.error("SSL error (try --allow-insecure-crypto to ignore): %s" % rootex)
            else:
                raise
        xml = ET.fromstring(res.content)
        if xml.tag != 'prelogin-response':
            p.error("This does not appear to be a GlobalProtect prelogin response\nCheck in browser: {}?{}".format(endpoint, urlencode(data)))
        status = xml.find('status')
        if status != None and status.text != 'Success':
            msg = xml.find('msg')
            if msg != None and msg.text == 'GlobalProtect {} does not exist'.format(args.interface):
                p.error("{} interface does not exist; specify {} instead".format(
                    args.interface.title(), '--portal' if args.interface=='gateway' else '--gateway'))
            else:
                p.error("Error in {} prelogin response: {}".format(args.interface, msg.text))
        sam = xml.find('saml-auth-method')
        sr = xml.find('saml-request')
        if sam is None or sr is None:
            p.error("{} prelogin response does not contain SAML tags (<saml-auth-method> or <saml-request> missing)\n\n"
                    "Things to try:\n"
                    "1) Spoof an officially supported OS (e.g. --clientos=Windows or --clientos=Mac)\n"
                    "2) Check in browser: {}?{}".format(args.interface.title(), endpoint, urlencode(data)))
        sam = sam.text
        sr = a2b_base64(sr.text).decode()
        if sam == 'POST':
            html, uri = sr, None
        elif sam == 'REDIRECT':
            uri, html = sr, None
        else:
            p.error("Unknown SAML method (%s)" % sam)

    # launch external browser for debugging
    if args.external:
        print("Got SAML %s, opening external browser for debugging..." % sam, file=stderr)
        import webbrowser
        if html:
            uri = 'data:text/html;base64,' + b2a_base64(html.encode()).decode()
        webbrowser.open(uri)
        raise SystemExit

    # spawn webview to do SAML interactive login
    if args.verbose:
        print("Got SAML %s, opening browser..." % sam, file=stderr)
    slv = SAMLLoginView(uri, html, verbose=args.verbose, user_agent=args.user_agent)
    if slv.closed:
        print("Login window closed by user.", file=stderr)
        p.exit(1)
    if not slv.success:
        p.error('''Login window closed without producing SAML cookies.''')

    # extract response and convert to OpenConnect command-line
    un = slv.saml_result.get('saml-username')
    server = slv.saml_result.get('server', args.server)

    for cn, ifh in (('prelogin-cookie','gateway'), ('portal-userauthcookie','portal')):
        cv = slv.saml_result.get(cn)
        if cv:
            break
    else:
        cn = ifh = None
        p.error("Didn't get an expected cookie. Something went wrong.")

    urlpath = args.interface + ":" + cn
    openconnect_args = [
        "--protocol=gp",
        "--user="+un,
        "--os="+args.ocos,
        "--usergroup="+urlpath,
        "--passwd-on-stdin",
        server
    ] + args.openconnect_extra

    if args.insecure:
        openconnect_args.insert(1, "--allow-insecure-crypto")
    if args.user_agent:
        openconnect_args.insert(1, "--useragent="+args.user_agent)
    if args.cert:
        cert, key = args.cert
        if key:
            openconnect_args.insert(1, "--sslkey="+key)
        openconnect_args.insert(1, "--certificate="+cert)

    openconnect_command = '''    echo {} |\n        sudo openconnect {}'''.format(
        quote(cv), " ".join(map(quote, openconnect_args)))

    if args.verbose:
        # Warn about ambiguities
        if server != args.server and not args.uri:
            print('''IMPORTANT: During the SAML auth, you were redirected from {0} to {1}. This probably '''
                  '''means you should specify {1} as the server for final connection, but we're not 100% '''
                  '''sure about this. You should probably try both.\n'''.format(args.server, server), file=stderr)
        if ifh != args.interface and not args.uri:
            print('''IMPORTANT: We started with SAML auth to the {} interface, but received a cookie '''
                  '''that's often associated with the {} interface. You should probably try both.\n'''.format(args.interface, ifh),
                  file=stderr)
        print('''\nSAML response converted to OpenConnect command line invocation:\n''', file=stderr)
        print(openconnect_command, file=stderr)

        print('''\nSAML response converted to test-globalprotect-login.py invocation:\n''', file=stderr)
        print('''    test-globalprotect-login.py --user={} --clientos={} -p '' \\\n         https://{}/{} {}={}\n'''.format(
            quote(un), quote(args.clientos), quote(server), quote(if2auth[args.interface]), quote(cn), quote(cv)), file=stderr)

    if args.exec == 'daemon':
        import json as _json
        import socket as _socket
        import signal as _signal
        # pywebview's Cocoa backend installs a Mach-port SIGINT handler via
        # AppHelper.installMachInterrupt() and does not restore it after app.run()
        # returns, which swallows Ctrl+C in the recv loop below. Re-arm Python's
        # default handler so Ctrl+C raises KeyboardInterrupt again.
        _signal.signal(_signal.SIGINT, _signal.default_int_handler)
        _HELPER_SOCKET = "/var/run/openconnect-helper.sock"
        print('Connecting to openconnect helper daemon, equivalent to:\n{}'.format(openconnect_command), file=stderr)
        try:
            sock = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
            sock.connect(_HELPER_SOCKET)
        except (FileNotFoundError, ConnectionRefusedError):
            print('ERROR: openconnect helper daemon not running.\n'
                  'Install it once with: sudo helper/install.sh', file=stderr)
            raise SystemExit(1)
        sock.sendall((_json.dumps({'args': openconnect_args, 'cookie': cv}) + '\n').encode())
        try:
            while True:
                data = sock.recv(4096)
                if not data:
                    break
                stderr.buffer.write(data)
                stderr.flush()
        except KeyboardInterrupt:
            pass
        finally:
            sock.close()
    elif args.exec:
        print('''Launching OpenConnect with {}, equivalent to:\n{}'''.format(args.exec, openconnect_command), file=stderr)
        with tempfile.TemporaryFile('w+') as tf:
            tf.write(cv)
            tf.flush()
            tf.seek(0)
            # redirect stdin from this file, before it is closed by the context manager
            # (it will remain accessible via the open file descriptor)
            dup2(tf.fileno(), 0)
        cmd = ["sudo", "openconnect"] + openconnect_args
        execvp(cmd[0], cmd)

    else:
        varvals = {
            'HOST': quote('https://%s/%s' % (server, urlpath)),
            'USER': quote(un), 'COOKIE': quote(cv), 'OS': quote(args.ocos),
        }
        print('\n'.join('%s=%s' % pair for pair in varvals.items()))

if __name__ == "__main__":
    main()
