# 번역 및 기술 검토 노트 (Translation & Verification Notes)

## 문서: `syz-execprog-design.md` -> `kor/syz-execprog-design.md`

### 1. 주요 용어 번역 및 개념 정립

- **Reproducer (`repro.syz`, `repro.c`, `pkg/repro`)**:
  - 문맥에 따라 **"재현 프로그램"** 및 **"재현 도구/재현 모듈"**로 구분하여 번역하였습니다. 프로그램 자체를 지칭할 때는 "재현 프로그램(reproducer)", 추출/검증 엔진을 지칭할 때는 "재현 모듈(`pkg/repro`)" 또는 맥락에 맞춰 표현하였습니다.
- **Per-call attribution**:
  - KCOV 커버리지가 특정 시스템 콜 호출 단위로 분리되어 수집되는 것을 의미하므로 **"호출별 귀속(per-call attribution)"**으로 번역하였습니다.
- **Arena / Copyin stream**:
  - 고정 가상 주소 영역을 나타내는 **"아레나(Arena)"**와 인자 데이터를 아레나에 적재하기 위한 명령어 스트림인 **"copyin 스트림"**은 시스템 소프트웨어의 표준 기술 관례에 맞춰 음차 및 원어를 병기하였습니다.
- **Subtractive parser**:
  - 정규 문법으로 엄격히 파싱하는 대신, 누적 버퍼에서 파싱에 실패한 라인을 버려가며 유효 접두사를 취하는 복구 방식을 **"감산형(subtractive) 파서"**로 직관적이면서도 명확하게 번역하였습니다.
- **Unrolled C statements**:
  - executor 인터프리터가 런타임에 루프로 해석하는 것과 대조적으로 C 소스 코드 상에 순차적 문장으로 직접 나열하여 출력하는 것을 **"펼쳐진(unrolled) C 문장"**으로 번역하였습니다.

### 2. 기술적 정확성 및 원문 대조 확인 사항

- **포인터 인코딩 상수 (`encodingAddrBase` vs 실제 아레나 베이스 주소)**:
  - 텍스트 상의 `&(0x7f0000000040)`에서 `0x7f0000000000`은 직렬화/역직렬화 시 더하고 빼는 표기상의 기준(textual base)일 뿐이며, 런타임에는 64비트 기준 `0x200000000000` (ARM은 `0x20000000`, 32비트는 `0x80000000`)에 16 MiB로 매핑된다는 점이 원문 설명과 코드 모두에서 정확함을 확인하였습니다.
- **타임아웃 계층 및 스케일링 비대칭성**:
  - syscall 타임아웃은 `slowdown` 배율에 선형 비례하지만, 전체 프로그램 및 무출력 타임아웃에 적용되는 `Scale`은 `min(slowdown, 3)`으로 상한선이 제한되어 있다는 점(의도된 비대칭 설계)을 누락 없이 정확히 번역하였습니다.
- **의사 시스템 콜(`syz_*`)의 처리 실패 동작**:
  - 미구현된 의사 시스템 콜이 0을 반환하면 후속 호출이 가짜 fd를 받아 버그를 재현하지 못하고 조용히 끝나는 치명적 함정을 강조하고, `ENOSYS` 반환 및 시작 시 목록을 알리는 원칙을 명확히 전달하였습니다.
- **Mermaid 다이어그램 및 마크다운 포맷**:
  - 모든 Mermaid 다이어그램, 테이블, 소스 코드 블록, 인용문 등이 원문의 구조와 1:1로 정확하게 보존되었습니다.

## `rust-clone-lab.md` 번역 검토 및 기술 검증 메모

- **문서 개요**: Rust를 사용하여 Linux 커널 대상의 미니멀 커버리지 가이드 시스템 콜 퍼저(syzkaller 축약 클론)를 제작하는 실습 가이드 (`rust-clone-lab.md`) 번역 완료.
- **용어 및 개념 검증**:
  1. **호스트/게스트 분리 (Host/Guest split)**: syzkaller가 2024년 정착시킨 아키텍처로, 영속 상태(코퍼스, 변이, 크래시 스캔)는 호스트에 두고 게스트는 단순 실행기(executor)만 두는 구조를 자연스럽게 설명.
  2. **KCOV 브래킷 및 프로토콜**:
     - `area[0]` = 수집된 PC 개수, `area[1..]` = PC 리스트 구조 및 `write_volatile(area, 0)` 방식의 리셋 메커니즘을 명확히 번역.
     - 호출 직전 `reset()`, 직후 `collect()`하는 브래킷의 중요성 강조.
     - asm-generic `_IOC` 인코딩에 따른 상수(`0x80086301`, `0x6364` 등)가 x86-64, arm64, riscv64에서 동일하다는 점과 MIPS/PowerPC/SPARC/Alpha에서의 차이점 보존.
  3. **PC 되감기 (`PC_REWIND`)**:
     - KCOV가 반환 주소를 보고하므로 직전 명령어로 되감는 오프셋(x86-64: 5, arm64/riscv64: 4, s390x: 6, mips64: 8) 설명 및 심볼화(`addr2line`) 관련 설명 정확히 번역.
  4. **신규성 검사(Novelty Check) 및 3단계 비용 파이프라인**:
     - 1회 실행(1x) → 신규 PC 발견 시 플레이크 완화(deflaking 3x) → 여전히 신규 시 최소화(minimization 20-30x)로 이어지는 비용 구조를 원문의 뉘앙스 그대로 보존.
  5. **베어메탈 보드 환경 및 전송/복구 계층**:
     - `musl` 정적 바이너리 크로스 컴파일, 제네릭 시스템 콜 ABI(`*at`, `*2` 형식 필수)의 제약 사항.
     - 콘솔 생존 채널(UART 시리얼 vs pstore/ramoops) 및 2단계 재부팅 대기(종료 확인 후 기동 확인)와 전원 차단 사다리(uhubctl 등)의 중요성 보존.
     - 9p-over-TCP 사용 시 `CONFIG_NET_9P_FD` 필요성 및 네트워크 FS와 퍼징 대상 간 서브시스템 공유 금지 원칙 명확화.
- **완전성 검증**:
  - 누락된 절, 머메이드 다이어그램, 코드 블록, 표, 레퍼런스 매핑 없이 100% 완전하게 번역됨.

## `syzlang-design.md`, `syz-manager-on-board-structure.md`, `mutation-design.md`, `history-of-major-feature-additions-and-revolutionary-design-changes.md` 번역 검토 및 기술 검증 메모

- **`syzlang-design.md`**:
  - `resource`, `syscall variant`, `squashing`, `arch-folded`, `desugaring` 등 syzlang 파이프라인(4단계: AST -> Typecheck -> Extract -> Fold)의 도메인 특화 용어를 표준 한국어 기술 문서 스타일에 맞춰 직관적 설명과 원어 병기로 정리.
  - Mermaid 다이어그램(10개 이상) 및 문법 디스패치 테이블, C 코드 생성/바이트 버퍼 인코딩 로직 1:1 보존 확인.

- **`syz-manager-on-board-structure.md`**:
  - `Pool vs Dispatcher` (생성/인스턴스화 책임 분리), `Dispatcher vs RPC Server` (작업 할당 분리), `Structured binary channel vs Serial console scrap` (크래시 로그 수집 채널 분리)의 3단계 감독자(Supervisor) 아키텍처 번역 검증.
  - 베어메탈(전원 차단 스위치, PoE, 하드웨어 와치독 리셋 사다리) 관련 실무 설정 뉘앙스 및 `GitRevisionKnown` 무결성 검사 로직 정확히 반영.

- **`mutation-design.md`**:
  - 5단계 중첩 계층 (L1: Program 구조 -> L2: Call 교체/추가 -> L3: Arg 인자 -> L4: Pointer/Buffer -> L5: Bits/Bytes) 및 상호보완적 선택 테이블(`ChoiceTable`) 우선순위 공식(`* 3/2` 가중치 비대칭 등) 확인.
  - `deflake` 통계 검증(5회 중 3회 성공 기준의 이항 분포 통과율 $B(5, 0.8) \ge 3 \approx 94.2\%$) 수식 및 의미 전달 보존.

- **`history-of-major-feature-additions-and-revolutionary-design-changes.md`**:
  - 2015년부터 2026년까지의 역사적 아키텍처 전환(FlatRPC 도입, syz-cluster, 호스트/게스트 책임 분리, 커널 descriptions 자동화 파이프라인 등) 타임라인과 커밋 해시, 다이어그램 전수 대조 완료.
