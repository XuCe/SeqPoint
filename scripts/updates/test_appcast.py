import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('appcast', Path(__file__).with_name('appcast.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'

class AppcastTest(unittest.TestCase):
    def test_platform_version_signature_length_and_immutable_url(self):
        with tempfile.TemporaryDirectory() as folder:
            asset = Path(folder) / 'seqpoint-v0.2.0-windows-x64-setup.exe'
            asset.write_bytes(b'installer')
            for platform, version, signature in [
                ('windows', '0.2.0+2', 'dsaSignature'), ('macos', '2', 'edSignature'),
            ]:
                xml = module.appcast(platform, '0.2.0+2', 'v0.2.0', asset, 'YWJj')
                item = ET.fromstring(xml).find('channel/item')
                self.assertEqual(item.find(NS+'version').text, version)
                enclosure = item.find('enclosure')
                self.assertEqual(enclosure.get('length'), str(asset.stat().st_size))
                self.assertEqual(enclosure.get(NS+signature), 'YWJj')
                self.assertEqual(enclosure.get('url'),
                    'https://github.com/XuCe/SeqPoint/releases/download/v0.2.0/'+asset.name)
                self.assertEqual(enclosure.get(NS+'installerArguments'),
                    '/SILENT /SP- /NOICONS /NORESTART' if platform == 'windows' else None)

    def test_rejects_missing_build_number(self):
        with self.assertRaises(ValueError):
            module.appcast('macos', '0.2.0', 'v0.2.0', Path('missing'), 'YWJj')

if __name__ == '__main__':
    unittest.main()
