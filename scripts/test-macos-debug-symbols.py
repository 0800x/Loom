"""Binary metadata fixtures; real Apple stripping is verified by native CI."""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('mac_debug', Path(__file__).with_name('strip-macos-debug.py'))
mac_debug = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mac_debug)


def thin(debug, wide=True, endian='<'):
    header, stride = (32, 16) if wide else (28, 12)
    data = bytearray(header + 24 + stride)
    struct.pack_into(endian + 'I', data, 0, 0xfeedfacf if wide else 0xfeedface)
    struct.pack_into(endian + 'II', data, 16, 1, 24)
    struct.pack_into(endian + 'IIIIII', data, header, 2, 24, header + 24, 1, len(data), 0)
    data[header + 24 + 4] = 0x66 if debug else 0x0f  # N_OSO vs normal external section symbol
    return bytes(data)


class MacDebugSymbols(unittest.TestCase):
    def test_thin_architectures_and_endianness(self):
        for wide in [False, True]:
            for endian in ['<', '>']:
                for debug in [False, True]:
                    with self.subTest(wide=wide, endian=endian, debug=debug):
                        self.assertEqual(mac_debug.has_debug_symbols(thin(debug, wide, endian)), debug)

    def test_universal_detects_debug_in_either_slice(self):
        for wide in [False, True]:
            for endian in ['<', '>']:
                for debug in [False, True]:
                    slices = [thin(False), thin(debug)]
                    stride = 32 if wide else 20
                    data = bytearray(8 + 2 * stride)
                    struct.pack_into(endian + 'II', data, 0, 0xcafebabf if wide else 0xcafebabe, 2)
                    for index, content in enumerate(slices):
                        struct.pack_into(endian + ('QQ' if wide else 'II'), data, 8 + index * stride + 8, len(data), len(content))
                        data.extend(content)
                    self.assertEqual(mac_debug.has_debug_symbols(data), debug)

    def test_stripped_and_non_macho_vendor_files_are_preserved(self):
        self.assertFalse(mac_debug.has_debug_symbols(b'not a Mach-O file'))
        data = bytearray(thin(False))
        struct.pack_into('<II', data, 16, 0, 0)
        self.assertFalse(mac_debug.has_debug_symbols(data))

    def test_truncated_symbol_table_fails(self):
        with self.assertRaisesRegex(ValueError, 'Truncated Mach-O symbol table'):
            mac_debug.has_debug_symbols(thin(True)[:-1])


if __name__ == '__main__':
    unittest.main()
