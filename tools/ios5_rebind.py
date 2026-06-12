#!/usr/bin/env python3
# ios5_rebind.py — post-link fix so AppDrop launches on iOS 5.x.
#
# On iOS 5, the Obj-C root-class symbols _OBJC_CLASS_$_NSObject / _OBJC_METACLASS_$_NSObject are
# exported by CoreFoundation, not libobjc (they moved into libobjc with the iOS 7 SDK's unified
# runtime). A binary linked against the 10.3 SDK records them as "expected in libobjc" → dyld
# bind failure → instant launch crash on iOS 5.1.1. This rewrites just those two symbols' bind
# records to point at CoreFoundation's dylib ordinal (which provides them on iOS 5 AND 6-10),
# leaving the genuine libobjc runtime symbols (objc_personality, OBJC_EHTYPE_id, objc_empty_cache)
# untouched — i.e. exactly the layout the old SDK-5.0 build produced. 32-bit armv7 Mach-O only.
#
# Usage: ios5_rebind.py <path-to-macho>   (edits in place; re-sign afterwards with ldid)
import struct, sys

MOVE_SYMBOLS = {"_OBJC_CLASS_$_NSObject", "_OBJC_METACLASS_$_NSObject"}
PTR = 4

def uleb(d, p):
    r = 0; s = 0
    while True:
        b = d[p]; p += 1; r |= (b & 0x7f) << s; s += 7
        if not (b & 0x80): break
    return r, p

def sleb(d, p):
    r = 0; s = 0
    while True:
        b = d[p]; p += 1; r |= (b & 0x7f) << s; s += 7
        if not (b & 0x80):
            if b & 0x40: r |= -(1 << s)
            break
    return r, p

def enc_uleb(v):
    out = bytearray()
    while True:
        b = v & 0x7f; v >>= 7
        if v: out.append(b | 0x80)
        else: out.append(b); break
    return bytes(out)

def enc_sleb(v):
    out = bytearray()
    more = True
    while more:
        b = v & 0x7f; v >>= 7
        if (v == 0 and not (b & 0x40)) or (v == -1 and (b & 0x40)):
            more = False
        else:
            b |= 0x80
        out.append(b)
    return bytes(out)

def parse_binds(d, off, size):
    """Expand the bind opcode stream into a flat list of records."""
    recs = []
    p = off; end = off + size
    seg = 0; segoff = 0; ordn = 0; sym = None; symflags = 0; btype = 1; addend = 0
    while p < end:
        b = d[p]; p += 1
        op = b & 0xF0; im = b & 0x0F
        if op == 0x00:  # DONE
            pass
        elif op == 0x10:  # SET_DYLIB_ORDINAL_IMM
            ordn = im
        elif op == 0x20:  # SET_DYLIB_ORDINAL_ULEB
            ordn, p = uleb(d, p)
        elif op == 0x30:  # SET_DYLIB_SPECIAL_IMM
            ordn = (im | 0xF0) - 0x100 if im else 0  # sign-extend small negative
        elif op == 0x40:  # SET_SYMBOL_TRAILING_FLAGS_IMM
            e = d.index(b"\0", p); sym = d[p:e].decode("latin1"); p = e + 1; symflags = im
        elif op == 0x50:  # SET_TYPE_IMM
            btype = im
        elif op == 0x60:  # SET_ADDEND_SLEB
            addend, p = sleb(d, p)
        elif op == 0x70:  # SET_SEGMENT_AND_OFFSET_ULEB
            seg = im; segoff, p = uleb(d, p); segoff &= 0xFFFFFFFF
        elif op == 0x80:  # ADD_ADDR_ULEB
            v, p = uleb(d, p); segoff = (segoff + v) & 0xFFFFFFFF
        elif op == 0x90:  # DO_BIND
            recs.append([seg, segoff, ordn, sym, symflags, btype, addend]); segoff = (segoff + PTR) & 0xFFFFFFFF
        elif op == 0xA0:  # DO_BIND_ADD_ADDR_ULEB
            recs.append([seg, segoff, ordn, sym, symflags, btype, addend])
            v, p = uleb(d, p); segoff = (segoff + PTR + v) & 0xFFFFFFFF
        elif op == 0xB0:  # DO_BIND_ADD_ADDR_IMM_SCALED
            recs.append([seg, segoff, ordn, sym, symflags, btype, addend]); segoff = (segoff + PTR + im * PTR) & 0xFFFFFFFF
        elif op == 0xC0:  # DO_BIND_ULEB_TIMES_SKIPPING_ULEB
            count, p = uleb(d, p); skip, p = uleb(d, p)
            for _ in range(count):
                recs.append([seg, segoff, ordn, sym, symflags, btype, addend]); segoff = (segoff + PTR + skip) & 0xFFFFFFFF
        else:
            raise ValueError("unknown bind opcode 0x%02x at %d" % (b, p - 1))
    return recs

def serialize_binds(recs):
    """Re-emit a correct (un-optimized) bind stream from records."""
    out = bytearray()
    cur_ord = None; cur_sym = None; cur_flags = None; cur_type = None; cur_add = 0
    for seg, segoff, ordn, sym, flags, btype, addend in recs:
        if ordn != cur_ord:
            if 0 < ordn < 16:
                out.append(0x10 | ordn)
            elif ordn >= 16:
                out.append(0x20); out += enc_uleb(ordn)
            else:
                out.append(0x30 | (ordn & 0x0F))
            cur_ord = ordn
        if sym != cur_sym or flags != cur_flags:
            out.append(0x40 | (flags & 0x0F)); out += sym.encode("latin1") + b"\0"
            cur_sym = sym; cur_flags = flags
        if btype != cur_type:
            out.append(0x50 | (btype & 0x0F)); cur_type = btype
        if addend != cur_add:
            out.append(0x60); out += enc_sleb(addend); cur_add = addend
        out.append(0x70 | (seg & 0x0F)); out += enc_uleb(segoff)
        out.append(0x90)  # DO_BIND
    out.append(0x00)  # DONE
    return bytes(out)

def main():
    path = sys.argv[1]
    d = bytearray(open(path, "rb").read())
    magic = struct.unpack_from("<I", d, 0)[0]
    if magic != 0xfeedface:
        raise SystemExit("not a 32-bit little-endian Mach-O (magic %08x)" % magic)
    ncmds = struct.unpack_from("<I", d, 16)[0]
    o = 28
    dylibs = []
    dyld_lc = None; symtab_lc = None; dysym_lc = None
    fnstarts_lc = None; dic_lc = None; codesig_lc = None; splitinfo_lc = None
    linkedit_lc = None
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", d, o)
        if cmd in (0x0c, 0x18, 0x1f):  # LOAD_DYLIB / LOAD_WEAK_DYLIB / REEXPORT_DYLIB
            noff = struct.unpack_from("<I", d, o + 8)[0]
            nm = d[o + noff:d.index(b"\0", o + noff)].decode("latin1")
            dylibs.append(nm)
        elif cmd in (0x22, 0x80000022):  # LC_DYLD_INFO(_ONLY)
            dyld_lc = o
        elif cmd == 0x02:  # LC_SYMTAB
            symtab_lc = o
        elif cmd == 0x0b:  # LC_DYSYMTAB
            dysym_lc = o
        elif cmd == 0x26:  # LC_FUNCTION_STARTS
            fnstarts_lc = o
        elif cmd == 0x29:  # LC_DATA_IN_CODE
            dic_lc = o
        elif cmd == 0x1d:  # LC_CODE_SIGNATURE
            codesig_lc = o
        elif cmd == 0x1e:  # LC_SEGMENT_SPLIT_INFO
            splitinfo_lc = o
        elif cmd == 0x01:  # LC_SEGMENT
            segname = d[o + 8:o + 24].split(b"\0", 1)[0]
            if segname == b"__LINKEDIT":
                linkedit_lc = o
        o += sz

    if dyld_lc is None:
        raise SystemExit("no LC_DYLD_INFO")
    (rebase_off, rebase_size, bind_off, bind_size, weak_off, weak_size,
     lazy_off, lazy_size, export_off, export_size) = struct.unpack_from("<10I", d, dyld_lc + 8)

    def ord_of(substr):
        for i, n in enumerate(dylibs, 1):
            if substr in n: return i
        return None
    cf_ord = ord_of("CoreFoundation.framework/CoreFoundation")
    objc_ord = ord_of("libobjc")
    if cf_ord is None:
        raise SystemExit("CoreFoundation not in load commands — add it to AppDrop_FRAMEWORKS")

    recs = parse_binds(d, bind_off, bind_size)
    moved = 0
    for r in recs:
        if r[3] in MOVE_SYMBOLS and r[2] == objc_ord:
            r[2] = cf_ord; moved += 1
    if moved == 0:
        # Already patched (or symbols not present) — leave untouched, success.
        print("ios5_rebind: nothing to move (already correct?) — leaving binary unchanged")
        return
    new_bind = serialize_binds(recs)

    # Pad new bind region to 8-byte alignment.
    new_bind_padded = new_bind + b"\x00" * ((-len(new_bind)) % 8)
    delta = len(new_bind_padded) - bind_size
    insert_end = bind_off + bind_size

    # Splice the new bind blob in place of the old one.
    newd = bytearray(d[:bind_off]) + new_bind_padded + bytearray(d[insert_end:])

    def bump(off):
        return off + delta if off and off >= insert_end else off

    # LC_DYLD_INFO: bind_size + shift later blobs.
    nb_size = len(new_bind)
    struct.pack_into("<10I", newd, dyld_lc + 8,
                     rebase_off, rebase_size, bind_off, nb_size,
                     bump(weak_off), weak_size, bump(lazy_off), lazy_size,
                     bump(export_off), export_size)
    # LC_SYMTAB
    if symtab_lc is not None:
        symoff, nsyms, stroff, strsize = struct.unpack_from("<4I", newd, symtab_lc + 8)
        struct.pack_into("<4I", newd, symtab_lc + 8, bump(symoff), nsyms, bump(stroff), strsize)
    # LC_DYSYMTAB (offset fields at specific positions)
    if dysym_lc is not None:
        vals = list(struct.unpack_from("<18I", newd, dysym_lc + 8))
        # indices of file-offset fields: tocoff(4), modtaboff(6), extrefsymoff(8),
        # indirectsymoff(10), extreloff(12), locreloff(14)
        for idx in (4, 6, 8, 10, 12, 14):
            vals[idx] = bump(vals[idx])
        struct.pack_into("<18I", newd, dysym_lc + 8, *vals)
    # LC_FUNCTION_STARTS / LC_DATA_IN_CODE / LC_SEGMENT_SPLIT_INFO / LC_CODE_SIGNATURE (dataoff,datasize)
    for lc in (fnstarts_lc, dic_lc, splitinfo_lc, codesig_lc):
        if lc is not None:
            doff, dsz = struct.unpack_from("<2I", newd, lc + 8)
            struct.pack_into("<2I", newd, lc + 8, bump(doff), dsz)
    # __LINKEDIT segment: grow filesize (and vmsize to cover it).
    if linkedit_lc is not None:
        # LC_SEGMENT layout: cmd,cmdsize,segname[16],vmaddr,vmsize,fileoff,filesize,...
        base = linkedit_lc + 8 + 16
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<4I", newd, base)
        filesize += delta
        vmsize = (filesize + 0xFFF) & ~0xFFF
        struct.pack_into("<4I", newd, base, vmaddr, vmsize, fileoff, filesize)

    open(path, "wb").write(newd)
    print("ios5_rebind: moved %d bind record(s) for %s from libobjc(ord %d) to CoreFoundation(ord %d); delta=%d bytes"
          % (moved, "/".join(sorted(MOVE_SYMBOLS)), objc_ord, cf_ord, delta))

if __name__ == "__main__":
    main()
