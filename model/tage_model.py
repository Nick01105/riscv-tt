"""Bit-exact Python model of rv_tage (same hash, update rules, LFSR and
useful-bit reset), plus a plain bimodal predictor for comparison."""


def fold(h, L, W):
    f = 0
    for i in range(L):
        f ^= ((h >> i) & 1) << (i % W)
    return f


class Bimodal:
    def __init__(self, entries, bits=2):
        self.n, self.bits = entries, bits
        self.t = [(1 << (bits - 1)) - 1] * entries          # weakly not taken

    def predict(self, pc, hist=0):
        return self.t[pc % self.n] >> (self.bits - 1), None

    def update(self, pc, hist, taken, meta):
        i, c, m = pc % self.n, self.t[pc % self.n], (1 << self.bits) - 1
        self.t[i] = min(c + 1, m) if taken else max(c - 1, 0)


class Tage:
    def __init__(self, pc_w=23, ghr_len=12, base_entries=64, nt=2, entries=16, tag_w=6, ctr_w=3, u_w=2,
                 hlens=(4, 12), reset_log=9):
        self.pc_w, self.ghr_len, self.nt, self.E = pc_w, ghr_len, nt, entries
        self.T, self.C, self.U, self.hl, self.reset_log = tag_w, ctr_w, u_w, list(hlens), reset_log
        self.I = (entries - 1).bit_length()
        self.base = Bimodal(base_entries)
        wn = (1 << (ctr_w - 1)) - 1
        self.tag = [[0] * entries for _ in range(nt)]
        self.ctr = [[wn] * entries for _ in range(nt)]
        self.u = [[0] * entries for _ in range(nt)]
        self.lfsr, self.cnt, self.plane = 0xACE1, 0, 0

    def hash(self, pc, hist, t):
        L = self.hl[t]
        h = hist & ((1 << L) - 1)
        im, tm = (1 << self.I) - 1, (1 << self.T) - 1
        idx = (pc & im) ^ ((pc >> self.I) & im) ^ fold(h, L, self.I)
        tag = (pc & tm) ^ fold(h, L, self.T) ^ ((fold(h, L, self.T - 1) << 1) & tm)
        return idx, tag

    def predict(self, pc, hist):
        meta = dict(base=self.base.t[pc % self.base.n], hit=[], ctr=[], u=[])
        taken = meta["base"] >> 1
        for t in range(self.nt):
            i, g = self.hash(pc, hist, t)
            hit = int(self.tag[t][i] == g)
            meta["hit"].append(hit)
            meta["ctr"].append(self.ctr[t][i])
            meta["u"].append(self.u[t][i])
            if hit:
                taken = self.ctr[t][i] >> (self.C - 1)
        return taken, meta

    def pack(self, meta):
        v = meta["base"]
        te = 1 + self.C + self.U
        for t in range(self.nt):
            v |= (meta["hit"][t] | (meta["ctr"][t] << 1) | (meta["u"][t] << (1 + self.C))) << (2 + t * te)
        return v

    def update(self, pc, hist, taken, meta):
        C, U = self.C, self.U
        cmax, umax = (1 << C) - 1, (1 << U) - 1
        prov, alt = None, None
        for t in range(self.nt):
            if meta["hit"][t]:
                alt, prov = prov, t
        prov_pred = meta["ctr"][prov] >> (C - 1) if prov is not None else None
        alt_pred = (meta["ctr"][alt] >> (C - 1)) if alt is not None else (meta["base"] >> 1)
        final = prov_pred if prov is not None else (meta["base"] >> 1)
        mispred = final != taken
        lo = -1 if prov is None else prov
        idxtag = [self.hash(pc, hist, t) for t in range(self.nt)]
        clr = 0
        if self.cnt == (1 << self.reset_log) - 1:
            clr = 1 << (0 if self.plane else U - 1)
        new_u = {}
        if prov is None:
            self.base.update(pc, hist, taken, None)
        else:
            i, g = idxtag[prov]
            c = meta["ctr"][prov]
            self.tag[prov][i] = g
            self.ctr[prov][i] = min(c + 1, cmax) if taken else max(c - 1, 0)
            if prov_pred != alt_pred:
                uu = meta["u"][prov]
                new_u[prov] = min(uu + 1, umax) if prov_pred == taken else max(uu - 1, 0)
        if mispred and lo < self.nt - 1:
            cands = [t for t in range(lo + 1, self.nt) if meta["u"][t] == 0]
            if cands:
                t = cands[1] if (len(cands) > 1 and self.lfsr & 1) else cands[0]
                i, g = idxtag[t]
                self.tag[t][i] = g
                self.ctr[t][i] = (1 << (C - 1)) if taken else (1 << (C - 1)) - 1
                new_u[t] = 0
            else:
                for t in range(lo + 1, self.nt):
                    new_u[t] = max(meta["u"][t] - 1, 0)
        # useful bits: clear plane everywhere, written entries get value & ~clr
        if clr:
            for t in range(self.nt):
                self.u[t] = [x & ~clr for x in self.u[t]]
        for t, v in new_u.items():
            self.u[t][idxtag[t][0]] = v & ~clr
        b = ((self.lfsr >> 15) ^ (self.lfsr >> 13) ^ (self.lfsr >> 12) ^ (self.lfsr >> 10)) & 1
        self.lfsr = ((self.lfsr << 1) & 0xFFFF) | b
        if self.cnt == (1 << self.reset_log) - 1:
            self.plane ^= 1
        self.cnt = (self.cnt + 1) % (1 << self.reset_log)
