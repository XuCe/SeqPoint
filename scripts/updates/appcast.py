"""Generate native update feeds from the final, signed release artifact."""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)

def appcast(platform, version, tag, asset, signature):
    match = re.fullmatch(r'(\d+\.\d+\.\d+)\+(\d+)', version)
    if match is None or platform not in ('macos', 'windows'):
        raise ValueError('Expected platform and version+build')
    root = ET.Element('rss', version='2.0')
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'SeqPoint'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'SeqPoint '+match[1]
    native_version = match[2] if platform == 'macos' else version
    ET.SubElement(item, '{%s}version' % SPARKLE).text = native_version
    ET.SubElement(item, '{%s}shortVersionString' % SPARKLE).text = match[1]
    attrs = {'url': 'https://github.com/XuCe/SeqPoint/releases/download/'+tag+'/'+asset.name,
             'length': str(asset.stat().st_size), 'type': 'application/octet-stream',
             '{%s}version' % SPARKLE: native_version,
             '{%s}shortVersionString' % SPARKLE: match[1],
             '{%s}os' % SPARKLE: 'macos' if platform == 'macos' else 'windows'}
    attrs['{%s}%s' % (SPARKLE, 'edSignature' if platform == 'macos' else 'dsaSignature')] = signature
    if platform == 'windows':
        attrs['{%s}installerArguments' % SPARKLE] = '/SILENT /SP- /NOICONS /NORESTART'
    ET.SubElement(item, 'enclosure', attrs)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)

def sign(platform, asset, tool):
    secret = os.environ['SPARKLE_PRIVATE_KEY' if platform == 'macos' else 'WINSPARKLE_PRIVATE_KEY']
    if not secret.strip():
        raise ValueError('Missing update signing key')
    with tempfile.TemporaryDirectory(prefix='seqpoint-sign-') as folder:
        key = Path(folder) / 'private.key'
        key.write_text(secret)
        key.chmod(0o600)
        if platform == 'macos':
            result = subprocess.run([tool, '--ed-key-file', str(key), str(asset)],
                capture_output=True, text=True, check=True)
            match = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', result.stdout)
            if not match:
                raise ValueError('Sparkle did not return a signature')
            return match[1]
        digest = hashlib.sha1()
        with asset.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        result = subprocess.run(['openssl', 'dgst', '-sha1', '-sign', str(key)],
            input=digest.digest(), capture_output=True, check=True)
        signature = Path(folder) / 'signature'
        signature.write_bytes(result.stdout)
        public = Path(__file__).resolve().parents[2] / 'apps/seqpoint_app/windows/runner/resources/update_dsa_pub.pem'
        subprocess.run(['openssl', 'dgst', '-sha1', '-verify', str(public),
            '-signature', str(signature)], input=digest.digest(), capture_output=True, check=True)
        return base64.b64encode(result.stdout).decode('ascii')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=['macos', 'windows'], required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--asset', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sparkle-tool', default='apps/seqpoint_app/macos/Pods/Sparkle/bin/sign_update')
    args = parser.parse_args()
    signature = sign(args.platform, args.asset, args.sparkle_tool)
    args.output.write_bytes(appcast(args.platform, args.version, args.tag, args.asset, signature))
    print('Signed update feed generated: '+args.output.name)
