"""AXI4 read-only slave memory model for cocotb, plus protocol checks.

* Accepts AR with random back-pressure; supports INCR and WRAP bursts.
* Returns R beats with random gaps; bursts with different IDs interleave
  (beats of one ID stay in order, as AXI requires).
* Error injection: reads that touch `err_lines` return SLVERR on every beat.
* Checks the master: AR payload stable and valid held until accepted;
  R taken only while RREADY is high; size/len/burst legal.

Signals are found by prefix on the DUT: <p>ar_valid, <p>ar_ready, <p>ar (flat
axi_ar_t), <p>r_valid, <p>r_ready, <p>r (flat axi_r_t).
"""
import random

from cocotb.triggers import FallingEdge, RisingEdge, Timer


def u(sig):
    v = sig.value
    return v.to_unsigned() if hasattr(v, "to_unsigned") else int(v)


class ArLayout:
    """Field layout of frontend_pkg::axi_ar_t / axi_r_t (first field = MSB)."""

    def __init__(self, id_w, addr_w, data_w):
        self.id_w, self.addr_w, self.data_w = id_w, addr_w, data_w

    def unpack_ar(self, v):
        prot, v = v & 7, v >> 3
        cache, v = v & 15, v >> 4
        lock, v = v & 1, v >> 1
        burst, v = v & 3, v >> 2
        size, v = v & 7, v >> 3
        length, v = v & 255, v >> 8
        addr, v = v & ((1 << self.addr_w) - 1), v >> self.addr_w
        return dict(id=v, addr=addr, len=length, size=size, burst=burst, lock=lock, cache=cache, prot=prot)

    def pack_r(self, rid, data, resp, last):
        return (((rid << self.data_w | data) << 2 | resp) << 1) | last


class AxiReadSlave:
    def __init__(self, dut, clk, mem_read, layout, prefix="", seed=1, p_ar_ready=0.6, p_beat=0.7,
                 max_delay=6, err_lines=(), line_bytes=16, on_ar=None, on_last=None):
        self.dut, self.clk, self.read, self.L = dut, clk, mem_read, layout
        self.ar_valid = getattr(dut, prefix + "ar_valid")
        self.ar_ready = getattr(dut, prefix + "ar_ready")
        self.ar = getattr(dut, prefix + "ar")
        self.r_valid = getattr(dut, prefix + "r_valid")
        self.r_ready = getattr(dut, prefix + "r_ready")
        self.r = getattr(dut, prefix + "r")
        self.r_rand = random.Random(seed)
        self.p_ar_ready, self.p_beat, self.max_delay = p_ar_ready, p_beat, max_delay
        self.err_lines = set(err_lines)
        self.line_bytes = line_bytes
        self.pending = {}            # id -> list of bursts (each a list of beats [delay, data, resp, last])
        self.ar_log = []             # accepted AR records
        self.beats = 0
        self.errors = []
        self.on_ar, self.on_last = on_ar, on_last

    def _burst(self, ar):
        nbytes = 1 << ar["size"]
        n = ar["len"] + 1
        if ar["burst"] not in (1, 2):
            self.errors.append(f"unsupported burst type {ar['burst']}")
        if ar["size"] > (self.L.data_w // 8).bit_length() - 1:
            self.errors.append(f"size {ar['size']} wider than the bus")
        if ar["burst"] == 2:
            if n not in (2, 4, 8, 16) or ar["addr"] % nbytes:
                self.errors.append(f"illegal WRAP burst len={n} addr={ar['addr']:#x}")
            total = n * nbytes
            base = ar["addr"] - ar["addr"] % total
            addrs = [base + (ar["addr"] - base + i * nbytes) % total for i in range(n)]
        else:
            addrs = [ar["addr"] + i * nbytes for i in range(n)]
        beats = []
        for i, a in enumerate(addrs):
            bad = (a // self.line_bytes) in self.err_lines
            data = 0 if bad else self.read(a, nbytes)
            lane = a % (self.L.data_w // 8)
            beats.append([self.r_rand.randint(0, self.max_delay), data << (8 * lane), 2 if bad else 0, int(i == n - 1)])
        return beats

    async def run(self):
        held_ar = None
        cur = None                   # (id, beat) being presented on R
        while True:
            await FallingEdge(self.clk)
            # ---- AR ----
            rdy = int(self.r_rand.random() < self.p_ar_ready)
            self.ar_ready.value = rdy
            # ---- R: keep presenting the current beat until accepted ----
            if cur is None:
                ready_ids = [i for i, q in self.pending.items() if q and q[0] and q[0][0][0] <= 0]
                for q in self.pending.values():
                    if q and q[0] and q[0][0][0] > 0:
                        q[0][0][0] -= 1
                if ready_ids and self.r_rand.random() < self.p_beat:
                    rid = self.r_rand.choice(ready_ids)
                    beat = self.pending[rid][0].pop(0)
                    if not self.pending[rid][0]:
                        self.pending[rid].pop(0)
                    cur = (rid, beat)
            if cur is not None:
                rid, (_, data, resp, last) = cur
                self.r_valid.value = 1
                self.r.value = self.L.pack_r(rid, data, resp, last)
            else:
                self.r_valid.value = 0
            await Timer(1, "ns")
            av = u(self.ar_valid)
            if held_ar is not None:
                if not av or u(self.ar) != held_ar:
                    self.errors.append("AR changed or dropped before it was accepted")
            held_ar = u(self.ar) if (av and not rdy) else None
            await RisingEdge(self.clk)
            if av and rdy:
                ar = self.L.unpack_ar(u(self.ar))
                self.ar_log.append(ar)
                self.pending.setdefault(ar["id"], []).append(self._burst(ar))
                if self.on_ar:
                    self.on_ar(ar)
            if cur is not None and u(self.r_ready):
                self.beats += 1
                if cur[1][3] and self.on_last:
                    self.on_last(cur[0])
                cur = None
