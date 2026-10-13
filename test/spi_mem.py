"""Behavioural SPI flash / PSRAM models (mode 0) for cocotb.

One SpiBus watches SCK, MOSI and the chip selects once per clock cycle and
drives MISO for the selected device. Supported commands: 0x03 READ (24-bit
address, data out until CS rises, address increments) and 0x02 WRITE
(PSRAM only; data in until CS rises). Anything else is recorded as an error.
Checks: one CS low at a time, CS high for at least `min_gap` cycles between
transactions, no SCK edges while CS is high, no writes to read-only devices.
"""
from cocotb.triggers import RisingEdge


def u(sig):
    v = sig.value
    return v.to_unsigned() if hasattr(v, "to_unsigned") else int(v)


class SpiDevice:
    def __init__(self, name, size, writable, data=None):
        self.name, self.size, self.writable = name, size, writable
        self.mem = bytearray(size) if data is None else data
        self.reads = self.writes = 0


class SpiBus:
    def __init__(self, dut, clk, devices, sck="sck", mosi="mosi", miso="miso", cs_n="cs_n", min_gap=2):
        self.dut, self.clk, self.dev = dut, clk, devices
        self.sck, self.mosi, self.miso, self.cs_n = (getattr(dut, n) if isinstance(n, str) else n
                                                     for n in (sck, mosi, miso, cs_n))
        self.min_gap = min_gap
        self.errors = []
        self.transactions = []         # (device, cmd, addr, nbytes)

    async def run(self):
        prev_sck, prev_cs = 0, (1 << len(self.dev)) - 1
        sel = None
        bits = nbits = 0
        cmd = addr = None
        out_byte = 0
        out_bit = 8
        wbyte = wbits = 0
        nbytes = 0
        gap = 99
        self.miso.value = 0
        while True:
            await RisingEdge(self.clk)
            sck, mosi, cs = u(self.sck), u(self.mosi), u(self.cs_n)
            low = [i for i in range(len(self.dev)) if not (cs >> i) & 1]
            if len(low) > 1:
                self.errors.append(f"several chip selects low: {cs:#b}")
            if cs != prev_cs:
                if low and prev_cs == (1 << len(self.dev)) - 1:          # CS falls: new transaction
                    if gap < self.min_gap:
                        self.errors.append(f"CS high for only {gap} cycles")
                    sel = self.dev[low[0]]
                    bits = nbits = 0
                    cmd = addr = None
                    out_bit = 8
                    wbits = 0
                    nbytes = 0
                elif not low and sel is not None:                         # CS rises: end
                    if cmd is not None:
                        self.transactions.append((sel.name, cmd, addr, nbytes))
                    if wbits:
                        self.errors.append("write ended mid-byte")
                    sel = None
                    gap = 0
            if not low:
                gap += 1
                if sck != prev_sck:
                    self.errors.append("SCK toggled with CS high")
                if sck:
                    self.errors.append("SCK high while idle")
            elif sel is not None:
                if sck and not prev_sck:                                  # rising edge: sample MOSI
                    if cmd is None or addr is None:
                        bits = (bits << 1) | mosi
                        nbits += 1
                        if cmd is None and nbits == 8:
                            cmd = bits
                            bits = nbits = 0
                            if cmd not in (0x02, 0x03):
                                self.errors.append(f"unknown command {cmd:#x}")
                        elif cmd is not None and nbits == 24:
                            addr = bits
                            if cmd == 0x02 and not sel.writable:
                                self.errors.append(f"write command to {sel.name}")
                    elif cmd == 0x02:
                        wbyte = (wbyte << 1) | mosi
                        wbits += 1
                        if wbits == 8:
                            if sel.writable:
                                sel.mem[(addr + nbytes) % sel.size] = wbyte
                                sel.writes += 1
                            nbytes += 1
                            wbits = wbyte = 0
                elif prev_sck and not sck and cmd == 0x03 and addr is not None:   # falling edge: next bit out
                    if out_bit == 8:
                        out_byte = sel.mem[(addr + nbytes) % sel.size]
                        nbytes += 1
                        sel.reads += 1
                        out_bit = 0
                    self.miso.value = (out_byte >> (7 - out_bit)) & 1
                    out_bit += 1
            prev_sck, prev_cs = sck, cs
