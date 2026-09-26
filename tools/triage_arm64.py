#!/usr/bin/env python3
# Copyright 2026 syzkaller project authors. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.

"""
AArch64-Specific Crash Classification and Hardware Syndrome Decoding Engine.

Implements the three-tier crash taxonomy and ARM64 architectural syndrome register
decoder for hypervisor attack-surface analysis on AArch64 (ARMv8-A / ARMv9-A).

Decodes:
  - ESR_EL1 / ESR_EL2 (Exception Syndrome Register):
      * EC  (bits [31:26]): Exception Class (Data Abort, Instruction Abort, SError, etc.)
      * IL  (bit  [25])   : Instruction Length (16-bit vs 32-bit instruction)
      * ISS (bits [24:0]) : Instruction Specific Syndrome (DFSC/IFSC fault codes, WnR, FnV, EA, S1PTW)
  - FAR_EL1 / FAR_EL2 (Fault Address Register):
      * Faulting Virtual Address (Null-pointer, EL0 userspace, EL1 kernel, KASAN shadow, etc.)

Classifies failure events into three strict tiers:
  - Category 1: Guest-Internal Panic (Oops, BUG, KASAN, Lockdep, Task Hung, kmemleak)
  - Category 2: VMM Process Failure (Rust panic/assert, C/C++ SIGSEGV/SIGBUS/ASan, Seccomp SIGSYS)
  - Category 3: Host Hypervisor Vulnerability (Host EL2 panic, Stage-2 Data Abort, KVM fault)
"""

import argparse
import glob
import json
import os
import re
import sys
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional, Tuple, Any

EXC_CLASS_MAP = {
    0x00: "Unknown / Unallocated Exception",
    0x01: "Trapped WFI or WFE Instruction",
    0x03: "Trapped MCR or MRC Access (CP15 AArch32)",
    0x04: "Trapped MCRR or MRRC Access (CP15 AArch32)",
    0x05: "Trapped MCR or MRC Access (CP14 AArch32)",
    0x06: "Trapped LDC or STC Access",
    0x07: "Trapped FP / SIMD Access",
    0x08: "Trapped VMRS Access",
    0x09: "Trapped PAuth Instruction",
    0x0A: "Trapped LD64B or ST64B Access",
    0x0C: "Trapped MRRC Access (CP14 AArch32)",
    0x0D: "Branch Target Exception (BTI)",
    0x0E: "Illegal Execution State",
    0x11: "SVC Instruction (AArch32)",
    0x12: "HVC Instruction (AArch32)",
    0x13: "SMC Instruction (AArch32)",
    0x15: "SVC Instruction (AArch64)",
    0x16: "HVC Instruction (AArch64)",
    0x17: "SMC Instruction (AArch64)",
    0x18: "Trapped MSR / MRS / System Instruction",
    0x19: "Trapped Access to SVE Functionality",
    0x1A: "Trapped ERET / ERETAA / ERETAB",
    0x1C: "Trapped Pointer Authentication Fault",
    0x20: "Instruction Abort (Lower Exception Level)",
    0x21: "Instruction Abort (Current Exception Level)",
    0x22: "PC Alignment Fault Exception",
    0x24: "Data Abort (Lower Exception Level)",
    0x25: "Data Abort (Current Exception Level)",
    0x26: "SP Alignment Fault Exception",
    0x28: "Trapped Floating-Point Exception (AArch32)",
    0x2C: "Trapped Floating-Point Exception (AArch64)",
    0x2F: "SError Interrupt",
    0x30: "Breakpoint Exception (Lower Exception Level)",
    0x31: "Breakpoint Exception (Current Exception Level)",
    0x32: "Software Step Exception (Lower Exception Level)",
    0x33: "Software Step Exception (Current Exception Level)",
    0x34: "Watchpoint Exception (Lower Exception Level)",
    0x35: "Watchpoint Exception (Current Exception Level)",
    0x38: "BKPT Instruction Execution (AArch32)",
    0x3A: "Vector Catch Exception (AArch32)",
    0x3C: "BRK Instruction Execution (AArch64)",
}

FAULT_STATUS_MAP = {
    0b000000: "Address Size Fault, Level 0",
    0b000001: "Address Size Fault, Level 1",
    0b000010: "Address Size Fault, Level 2",
    0b000011: "Address Size Fault, Level 3",
    0b000100: "Translation Fault, Level 0",
    0b000101: "Translation Fault, Level 1",
    0b000110: "Translation Fault, Level 2",
    0b000111: "Translation Fault, Level 3",
    0b001001: "Access Flag Fault, Level 1",
    0b001010: "Access Flag Fault, Level 2",
    0b001011: "Access Flag Fault, Level 3",
    0b001101: "Permission Fault, Level 1",
    0b001110: "Permission Fault, Level 2",
    0b001111: "Permission Fault, Level 3",
    0b010000: "Synchronous External Abort (Not on Table Walk)",
    0b010001: "Synchronous Tag Check Fault",
    0b010100: "Synchronous External Abort on Table Walk, Level 0",
    0b010101: "Synchronous External Abort on Table Walk, Level 1",
    0b010110: "Synchronous External Abort on Table Walk, Level 2",
    0b010111: "Synchronous External Abort on Table Walk, Level 3",
    0b011000: "Synchronous Parity or ECC Error on Memory Access",
    0b011100: "Synchronous Parity or ECC Error on Table Walk, Level 0",
    0b011101: "Synchronous Parity or ECC Error on Table Walk, Level 1",
    0b011110: "Synchronous Parity or ECC Error on Table Walk, Level 2",
    0b011111: "Synchronous Parity or ECC Error on Table Walk, Level 3",
    0b100001: "Alignment Fault",
    0b100010: "Debug Event",
    0b110000: "TLB Conflict Abort",
    0b110001: "Unsupported Atomic Hardware Update Fault",
    0b110100: "Implementation Defined Fault (Lockdown)",
    0b110101: "Implementation Defined Fault (Unsupported Exclusive)",
}

@dataclass
class SyndromeDecoded:
    raw_esr: int
    raw_far: Optional[int]
    exception_class_code: int
    exception_class_name: str
    instruction_length: str
    iss_raw: int
    fault_type: Optional[str] = None
    write_not_read: Optional[bool] = None
    stage2_s1ptw: Optional[bool] = None
    far_valid: Optional[bool] = None
    address_category: Optional[str] = None
    details: Optional[str] = None

def decode_arm64_esr(esr: int, far: Optional[int] = None) -> SyndromeDecoded:
    ec = (esr >> 26) & 0x3F
    il = (esr >> 25) & 0x01
    iss = esr & 0x1FFFFFF

    ec_name = EXC_CLASS_MAP.get(ec, f"Unknown (0x{ec:02x})")
    il_str = "32-bit" if il == 1 else "16-bit"

    fault_type = None
    wnr = None
    s1ptw = None
    fnv = None
    details = []

    if ec in (0x20, 0x21, 0x24, 0x25):
        fsc = iss & 0x3F
        fault_type = FAULT_STATUS_MAP.get(fsc, f"Unknown Fault Status (0b{fsc:06b})")
        details.append(f"FSC: {fault_type}")

        if ec in (0x24, 0x25):
            wnr = bool((iss >> 6) & 1)
            s1ptw = bool((iss >> 7) & 1)
            cm = bool((iss >> 8) & 1)
            fnv = not bool((iss >> 10) & 1)

            details.append(f"Access: {'Write' if wnr else 'Read'}")
            if s1ptw:
                details.append("Fault on Stage-2 Walk for Stage-1 Page Table (S1PTW)")
            if cm:
                details.append("Cache Maintenance Operation")
            if fnv:
                details.append("FAR is Valid")
            else:
                details.append("FAR is Not Valid (FnV=1)")
    elif ec == 0x2F:
        aet = (iss >> 10) & 0x07
        aet_map = {0: "Uncontainable", 1: "Uncategorized", 2: "Restarter", 3: "Recoverable", 6: "Corrected"}
        details.append(f"SError AET: {aet_map.get(aet, f'0x{aet:x}')}")
    elif ec == 0x3C:
        imm16 = iss & 0xFFFF
        details.append(f"BRK immediate: 0x{imm16:04x}")

    addr_cat = None
    if far is not None:
        if far == 0:
            addr_cat = "NULL Pointer Dereference (0x0)"
        elif far < 0x1000:
            addr_cat = f"Near-NULL Pointer Offset (0x{far:x})"
        elif far <= 0x0000FFFFFFFFFFFF:
            addr_cat = "Userspace Virtual Address (EL0 Range)"
        elif 0xFFFF000000000000 <= far <= 0xFFFFFFFFFFFFFFFF:
            if 0xFFFF800000000000 <= far <= 0xFFFFFF8000000000:
                addr_cat = "Kernel Vmalloc / Module Virtual Address"
            else:
                addr_cat = "Kernel Direct Mapping / Linear Address (EL1 Range)"
        else:
            addr_cat = "Non-Canonical / Stage-2 Physical Fault Address"

    return SyndromeDecoded(
        raw_esr=esr,
        raw_far=far,
        exception_class_code=ec,
        exception_class_name=ec_name,
        instruction_length=il_str,
        iss_raw=iss,
        fault_type=fault_type,
        write_not_read=wnr,
        stage2_s1ptw=s1ptw,
        far_valid=fnv,
        address_category=addr_cat,
        details="; ".join(details) if details else None
    )

CATEGORY_GUEST_PANIC = "Category 1: Guest-Internal Panic"
CATEGORY_VMM_FAILURE = "Category 2: VMM Process Failure"
CATEGORY_HOST_KVM_FAULT = "Category 3: Host/KVM Vulnerability"

@dataclass
class CrashClassification:
    crash_id: str
    target: str
    sandbox: str
    run_name: str
    title: str
    category: str
    subcategory: str
    fault_source: str
    syndrome: Optional[SyndromeDecoded] = None
    evidence: Optional[str] = None
    seccomp_violation: bool = False

class AArch64TriageEngine:
    CAT1_PATTERNS = [
        (r"Internal error:\s+Oops(?::\s+([0-9a-fA-F]+))?", "KERNEL_OOPS"),
        (r"BUG:\s+KASAN:\s+([^\n\r]+)", "KASAN_FAULT"),
        (r"BUG:\s+unable to handle page fault", "KERNEL_PAGE_FAULT"),
        (r"BUG:\s+memory leak", "KMEMLEAK"),
        (r"INFO:\s+task [^\n\r]+ blocked for more than \d+ seconds", "HUNG_TASK"),
        (r"INFO:\s+possible recursive locking detected", "LOCKDEP_WARNING"),
        (r"Kernel panic - not syncing:\s+([^\n\r]+)", "KERNEL_PANIC"),
        (r"no output from test machine", "GUEST_CONSOLE_STALL"),
        (r"suppressed report", "SUPPRESSED_LOCKDEP"),
        (r"WARNING:\s+at\s+([^\n\r]+)", "KERNEL_WARNING"),
    ]

    CAT2_PATTERNS = [
        (r"panicked at\s+['\"]?([^'\"\n\r]+)", "RUST_PANIC"),
        (r"fatal runtime error:\s+([^\n\r]+)", "RUST_RUNTIME_ERROR"),
        (r"called `Result::unwrap\(\)` on an `Err` value", "RUST_UNWRAP_ERR"),
        (r"called `Option::unwrap\(\)` on a `None` value", "RUST_UNWRAP_NONE"),
        (r"index out of bounds:\s+([^\n\r]+)", "RUST_BOUNDS_PANIC"),
        (r"qemu-system-aarch64:.*assertion failed", "QEMU_ASSERTION_FAILURE"),
        (r"AddressSanitizer:\s+([^\n\r]+)", "QEMU_ASAN_ABORT"),
        (r"Segmentation fault", "VMM_SIGSEGV"),
        (r"Bus error", "VMM_SIGBUS"),
        (r"Bad system call", "SECCOMP_SIGSYS"),
    ]

    CAT3_PATTERNS = [
        (r"Unhandled Stage-2 [^:\n\r]+", "STAGE2_ABORT"),
        (r"kvm \[.*\]:.*guest trap", "KVM_TRAP_ERROR"),
        (r"arch/arm64/kvm/.*assertion", "KVM_HYP_ASSERTION"),
        (r"Host kernel panic", "HOST_PANIC"),
        (r"hyp mode panic", "HOST_EL2_PANIC"),
    ]

    def extract_syndrome(self, text: str) -> Optional[SyndromeDecoded]:
        esr_val = None
        far_val = None

        m_esr = re.search(r"ESR(?:_EL[12])?\s*=\s*0x([0-9a-fA-F]+)", text)
        if m_esr:
            esr_val = int(m_esr.group(1), 16)
        else:
            m_oops = re.search(r"Internal error:\s+Oops:\s+([0-9a-fA-F]{8})", text)
            if m_oops:
                esr_val = int(m_oops.group(1), 16)

        m_far = re.search(r"FAR(?:_EL[12])?\s*=\s*0x([0-9a-fA-F]+)", text)
        if m_far:
            far_val = int(m_far.group(1), 16)

        if esr_val is not None:
            return decode_arm64_esr(esr_val, far_val)
        return None

    def classify_log(self, crash_id: str, target: str, sandbox: str, run_name: str, title: str, content: str) -> CrashClassification:
        syndrome = self.extract_syndrome(content)

        # Tier 3 check: Host / KVM layer
        for pattern, subcat in self.CAT3_PATTERNS:
            m = re.search(pattern, content)
            if m:
                return CrashClassification(
                    crash_id=crash_id,
                    target=target,
                    sandbox=sandbox,
                    run_name=run_name,
                    title=title,
                    category=CATEGORY_HOST_KVM_FAULT,
                    subcategory=subcat,
                    fault_source="Host EL2 / KVM Subsystem",
                    syndrome=syndrome,
                    evidence=m.group(0),
                )

        # Tier 2 check: VMM process crash / abort
        seccomp_viol = False
        for pattern, subcat in self.CAT2_PATTERNS:
            m = re.search(pattern, content)
            if m:
                if subcat == "SECCOMP_SIGSYS":
                    seccomp_viol = True
                return CrashClassification(
                    crash_id=crash_id,
                    target=target,
                    sandbox=sandbox,
                    run_name=run_name,
                    title=title,
                    category=CATEGORY_VMM_FAILURE,
                    subcategory=subcat,
                    fault_source="VMM Userspace Runtime",
                    syndrome=syndrome,
                    evidence=m.group(0),
                    seccomp_violation=seccomp_viol,
                )

        # Tier 1 check: Guest-Internal Panic
        for pattern, subcat in self.CAT1_PATTERNS:
            m = re.search(pattern, content)
            if m:
                return CrashClassification(
                    crash_id=crash_id,
                    target=target,
                    sandbox=sandbox,
                    run_name=run_name,
                    title=title,
                    category=CATEGORY_GUEST_PANIC,
                    subcategory=subcat,
                    fault_source="Guest Kernel EL1",
                    syndrome=syndrome,
                    evidence=m.group(0),
                )

        # Fallback heuristic based on title
        subcat = "GENERIC_GUEST_ERROR"
        if "hung" in title.lower():
            subcat = "HUNG_TASK"
        elif "leak" in title.lower():
            subcat = "KMEMLEAK"
        elif "no output" in title.lower():
            subcat = "GUEST_CONSOLE_STALL"

        return CrashClassification(
            crash_id=crash_id,
            target=target,
            sandbox=sandbox,
            run_name=run_name,
            title=title,
            category=CATEGORY_GUEST_PANIC,
            subcategory=subcat,
            fault_source="Guest Kernel EL1",
            syndrome=syndrome,
            evidence=title,
        )

def scan_campaign_runs(runs_dir: str) -> List[CrashClassification]:
    engine = AArch64TriageEngine()
    results = []

    run_dirs = sorted(glob.glob(os.path.join(runs_dir, "*-*")))
    for rdir in run_dirs:
        bname = os.path.basename(rdir)
        parts = bname.split("-")
        if len(parts) < 2:
            continue
        target = parts[0]
        sandbox = parts[1]

        crashes_dir = os.path.join(rdir, "workdir", "crashes")
        if not os.path.exists(crashes_dir):
            continue

        for cid in sorted(os.listdir(crashes_dir)):
            cpath = os.path.join(crashes_dir, cid)
            if not os.path.isdir(cpath):
                continue

            desc_file = os.path.join(cpath, "description")
            title = open(desc_file).read().strip() if os.path.exists(desc_file) else "unknown"

            combined_content = [title]
            for fn in ["report0", "report1", "log0", "log1"]:
                fpath = os.path.join(cpath, fn)
                if os.path.exists(fpath):
                    try:
                        combined_content.append(open(fpath, errors="ignore").read()[:50000])
                    except Exception:
                        pass

            content_text = "\n".join(combined_content)
            res = engine.classify_log(
                crash_id=cid,
                target=target,
                sandbox=sandbox,
                run_name=bname,
                title=title,
                content=content_text,
            )
            results.append(res)

    return results

def print_summary_report(results: List[CrashClassification]):
    print("=" * 80)
    print("AArch64 Crash Triage & Architectural Syndrome Classification Summary")
    print("=" * 80)
    print(f"Total Unique Crash Instances Evaluated: {len(results)}\n")

    cat_counts = {CATEGORY_GUEST_PANIC: 0, CATEGORY_VMM_FAILURE: 0, CATEGORY_HOST_KVM_FAULT: 0}
    target_counts: Dict[str, Dict[str, int]] = {}
    sandbox_counts: Dict[str, Dict[str, int]] = {}
    subcat_counts: Dict[str, int] = {}
    syndromes_decoded: List[CrashClassification] = []

    for r in results:
        cat_counts[r.category] = cat_counts.get(r.category, 0) + 1
        target_counts.setdefault(r.target, {}).setdefault(r.category, 0)
        target_counts[r.target][r.category] += 1

        sandbox_counts.setdefault(r.sandbox, {}).setdefault(r.category, 0)
        sandbox_counts[r.sandbox][r.category] += 1

        subcat_counts[r.subcategory] = subcat_counts.get(r.subcategory, 0) + 1
        if r.syndrome:
            syndromes_decoded.append(r)

    print("1. Three-Tier Taxonomy Totals:")
    for cat in [CATEGORY_GUEST_PANIC, CATEGORY_VMM_FAILURE, CATEGORY_HOST_KVM_FAULT]:
        pct = (cat_counts.get(cat, 0) / len(results) * 100) if results else 0
        print(f"  * {cat:42s} : {cat_counts.get(cat, 0):4d} ({pct:5.1f}%)")

    print("\n2. Breakdown by Hypervisor Target:")
    print(f"  {'Target':<14s} {'Cat 1 (Guest)':<16s} {'Cat 2 (VMM)':<16s} {'Cat 3 (Host/KVM)':<18s}")
    for target in sorted(target_counts):
        c1 = target_counts[target].get(CATEGORY_GUEST_PANIC, 0)
        c2 = target_counts[target].get(CATEGORY_VMM_FAILURE, 0)
        c3 = target_counts[target].get(CATEGORY_HOST_KVM_FAULT, 0)
        print(f"  {target:<14s} {c1:<16d} {c2:<16d} {c3:<18d}")

    print("\n3. Breakdown by Sandbox Mode:")
    print(f"  {'Sandbox':<14s} {'Cat 1 (Guest)':<16s} {'Cat 2 (VMM)':<16s} {'Cat 3 (Host/KVM)':<18s}")
    for sb in sorted(sandbox_counts):
        c1 = sandbox_counts[sb].get(CATEGORY_GUEST_PANIC, 0)
        c2 = sandbox_counts[sb].get(CATEGORY_VMM_FAILURE, 0)
        c3 = sandbox_counts[sb].get(CATEGORY_HOST_KVM_FAULT, 0)
        print(f"  {sb:<14s} {c1:<16d} {c2:<16d} {c3:<18d}")

    print("\n4. Failure Subcategory Frequency:")
    for subcat, cnt in sorted(subcat_counts.items(), key=lambda x: x[1], reverse=True):
        print(f"  * {subcat:32s} : {cnt:4d}")

    print("\n5. Hardware Syndrome Registers (ESR_ELx / FAR_ELx) Extracted:")
    if syndromes_decoded:
        for r in syndromes_decoded:
            s = r.syndrome
            print(f"  * Crash [{r.crash_id[:12]}] ({r.target}/{r.sandbox}): {r.title}")
            print(f"      ESR=0x{s.raw_esr:08x} -> EC=0x{s.exception_class_code:02x} ({s.exception_class_name}), IL={s.instruction_length}")
            if s.fault_type:
                print(f"      Fault Status: {s.fault_type} | Access: {'Write' if s.write_not_read else 'Read'}")
            if s.raw_far is not None:
                print(f"      FAR=0x{s.raw_far:016x} -> {s.address_category}")
    else:
        print("  * No architectural syndrome register dumps encountered in dataset.")
        print("    (All observed failures were software-level hangs, memory leaks, or console stalls contained within EL1).")

    print("\n" + "=" * 80)

def run_self_tests():
    print("Running AArch64 Crash Triage & Syndrome Decoder Self-Tests...\n")
    engine = AArch64TriageEngine()

    test_cases = [
        {
            "name": "Case 1: EL1 Kernel NULL Pointer Dereference (Data Abort)",
            "log": (
                "Unable to handle kernel NULL pointer dereference at virtual address 0000000000000008\n"
                "Mem abort info:\n"
                "  ESR_EL1 = 0x0000000096000004\n"
                "  EC = 0x25: Data Abort taken without a change in Exception level, ISS = 0x00000004\n"
                "  FSC = 0x04: level 0 translation fault\n"
                "  FAR_EL1 = 0x0000000000000008\n"
                "Internal error: Oops: 96000004 [#1] PREEMPT SMP\n"
            ),
            "expected_cat": CATEGORY_GUEST_PANIC,
            "expected_subcat": "KERNEL_OOPS",
            "expected_ec": 0x25,
            "expected_fsc": "Translation Fault, Level 0",
        },
        {
            "name": "Case 2: EL1 Kernel Permission Fault (Write to Read-Only)",
            "log": (
                "Internal error: Oops: 9600004f [#2] PREEMPT SMP\n"
                "ESR_EL1 = 0x000000009600004f\n"
                "FAR_EL1 = 0xffff800012345678\n"
            ),
            "expected_cat": CATEGORY_GUEST_PANIC,
            "expected_subcat": "KERNEL_OOPS",
            "expected_ec": 0x25,
            "expected_fsc": "Permission Fault, Level 3",
        },
        {
            "name": "Case 3: Rust VMM Memory Safety Abort (crosvm / Firecracker)",
            "log": (
                "thread 'virtio-blk' panicked at 'index out of bounds: the len is 16 but the index is 32',\n"
                "devices/src/virtio/block.rs:412:13\n"
                "fatal runtime error: failed to initiate panic\n"
            ),
            "expected_cat": CATEGORY_VMM_FAILURE,
            "expected_subcat": "RUST_PANIC",
            "expected_ec": None,
            "expected_fsc": None,
        },
        {
            "name": "Case 4: C/C++ VMM Process Segmentation Fault (QEMU)",
            "log": (
                "qemu-system-aarch64: /home/debian-sid/qemu/hw/virtio/virtio-mmio.c:182: "
                "AddressSanitizer: heap-buffer-overflow on address 0x619000001000\n"
                "Segmentation fault (core dumped)\n"
            ),
            "expected_cat": CATEGORY_VMM_FAILURE,
            "expected_subcat": "QEMU_ASAN_ABORT",
            "expected_ec": None,
            "expected_fsc": None,
        },
        {
            "name": "Case 5: Host Hypervisor Stage-2 Fault / KVM Abort",
            "log": (
                "Unhandled Stage-2 Data Abort for guest physical address 0x40001000 at EL2\n"
                "kvm [1201]: Stage-2 translation fault unhandled by hypervisor\n"
                "Host kernel panic - not syncing: Fatal KVM EL2 trap\n"
            ),
            "expected_cat": CATEGORY_HOST_KVM_FAULT,
            "expected_subcat": "STAGE2_ABORT",
            "expected_ec": None,
            "expected_fsc": None,
        },
    ]

    all_passed = True
    for tc in test_cases:
        res = engine.classify_log(
            crash_id="test",
            target="qemu",
            sandbox="none",
            run_name="test-run",
            title=tc["name"],
            content=tc["log"],
        )

        cat_ok = res.category == tc["expected_cat"]
        subcat_ok = res.subcategory == tc["expected_subcat"]
        ec_ok = True
        fsc_ok = True
        if tc["expected_ec"] is not None:
            ec_ok = res.syndrome is not None and res.syndrome.exception_class_code == tc["expected_ec"]
        if tc["expected_fsc"] is not None:
            fsc_ok = res.syndrome is not None and res.syndrome.fault_type == tc["expected_fsc"]

        passed = cat_ok and subcat_ok and ec_ok and fsc_ok
        status = "PASSED" if passed else "FAILED"
        if not passed:
            all_passed = False
        print(f"[{status}] {tc['name']}")
        print(f"  Category   : {res.category} (Expected: {tc['expected_cat']})")
        print(f"  Subcategory: {res.subcategory} (Expected: {tc['expected_subcat']})")
        if res.syndrome:
            print(f"  Syndrome   : EC=0x{res.syndrome.exception_class_code:02x} ({res.syndrome.exception_class_name})")
            if res.syndrome.fault_type:
                print(f"  Fault Type : {res.syndrome.fault_type}")
            if res.syndrome.raw_far is not None:
                print(f"  FAR_EL1    : 0x{res.syndrome.raw_far:x} ({res.syndrome.address_category})")
        print()

    if all_passed:
        print(">> ALL UNIT TESTS COMPLETED SUCCESSFULLY! <<\n")
    else:
        print(">> SOME UNIT TESTS FAILED! <<\n")
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="AArch64 Crash Triage & Syndrome Register Classification Engine.")
    parser.add_argument("--runs-dir", default="/home/debian-sid/.cache/syz-crosvm/runs", help="Path to campaign runs directory")
    parser.add_argument("--file", help="Analyze a single log file or crash report")
    parser.add_argument("--decode-esr", help="Hex value of ESR_EL1/ESR_EL2 to decode (e.g. 0x96000004)")
    parser.add_argument("--decode-far", help="Optional hex value of FAR_EL1/FAR_EL2 to accompany --decode-esr")
    parser.add_argument("--json", action="store_true", help="Output raw JSON results")
    parser.add_argument("--test", action="store_true", help="Run self-tests verifying syndrome decoding and 3-tier classification")

    args = parser.parse_args()

    if args.test:
        run_self_tests()
        return

    if args.decode_esr:
        esr_int = int(args.decode_esr, 16)
        far_int = int(args.decode_far, 16) if args.decode_far else None
        decoded = decode_arm64_esr(esr_int, far_int)
        if args.json:
            print(json.dumps(asdict(decoded), indent=2))
        else:
            print("=" * 60)
            print(f"AArch64 ESR Decoder: 0x{decoded.raw_esr:08x}")
            print("=" * 60)
            print(f"Exception Class (EC)   : 0x{decoded.exception_class_code:02x} ({decoded.exception_class_name})")
            print(f"Instruction Length (IL): {decoded.instruction_length}")
            print(f"ISS Raw                : 0x{decoded.iss_raw:06x} ({decoded.iss_raw})")
            if decoded.fault_type:
                print(f"Fault Status Code (FSC): {decoded.fault_type}")
                print(f"Access Direction       : {'Write' if decoded.write_not_read else 'Read'}")
            if decoded.raw_far is not None:
                print(f"FAR_ELx Register       : 0x{decoded.raw_far:016x} -> {decoded.address_category}")
            if decoded.details:
                print(f"Syndrome Attributes    : {decoded.details}")
        return

    if args.file:
        engine = AArch64TriageEngine()
        content = open(args.file, errors="ignore").read()
        res = engine.classify_log(
            crash_id=os.path.basename(args.file),
            target="unknown",
            sandbox="unknown",
            run_name="manual-file",
            title=os.path.basename(args.file),
            content=content,
        )
        if args.json:
            print(json.dumps(asdict(res), indent=2))
        else:
            print(f"Category   : {res.category}")
            print(f"Subcategory: {res.subcategory}")
            print(f"Fault Layer: {res.fault_source}")
            if res.syndrome:
                print(f"Syndrome   : EC=0x{res.syndrome.exception_class_code:02x} ({res.syndrome.exception_class_name})")
                if res.syndrome.raw_far is not None:
                    print(f"FAR        : 0x{res.syndrome.raw_far:x} ({res.syndrome.address_category})")
        return

    if not os.path.exists(args.runs_dir):
        print(f"Error: runs directory not found: {args.runs_dir}", file=sys.stderr)
        sys.exit(1)

    results = scan_campaign_runs(args.runs_dir)
    if args.json:
        dict_results = [asdict(r) for r in results]
        print(json.dumps(dict_results, indent=2))
    else:
        print_summary_report(results)

if __name__ == "__main__":
    main()
