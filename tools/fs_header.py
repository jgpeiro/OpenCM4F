"""Adds the comment header that Gowin's own tools write at the top of a .fs bitstream (part number,
device, version) to a bitstream from gowin_pack, so the Gowin Programmer shows and checks the device.
The bitstream itself is unchanged (it already carries the IDCODE 0x0000081B of the GW2AR-18C).
usage: fs_header.py file.fs [title]"""
import sys, time
path = sys.argv[1]
lines = open(path).read().splitlines()
body = [l for l in lines if not l.startswith('//')]
hdr = [
    '//File Title: Bitstream file',
    '//Tool: open-source flow (yosys, nextpnr-himbaechel, apicula gowin_pack) - OpenCM4F',
    '//Part Number: GW2AR-LV18QN88C8/I7',
    '//Device: GW2AR-18',
    '//Device Version: C',
    '//Created Time: ' + time.strftime('%a %b %d %H:%M:%S %Y'),
]
open(path, 'w').write('\n'.join(hdr + body) + '\n')
print(path, ': header written')
